import os, strutils, strformat, httpclient, hjson, json, tables, times, sugar, base64, re

# Blacklist for repositories
const repoNameBlacklist: Table[string, string] = {
  "animdustry-mod-template": "Template mod",
}.toTable

# Blacklist for user names
const userNameBlacklist = initTable[string, string]()

const timeFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"

proc isOk(r: Response): bool = r.status == "200 OK"

proc findIndex[T](s: openArray[T], predicate: (proc(x: T): bool)): int =
  for i, x in s:
    if(x.predicate):
      return i
  return -1

proc modError(repo: string, acceptable: bool, description: string, details = description): JsonNode =
  return %* { "repository": repo, "description": description, "details": details, "acceptable": acceptable }

proc namespaceValid(namespace: string): bool =
  # Namespace must be a valid JavaScript identifier
  const rx = re"^[a-zA-Z_][0-9a-zA-Z_]*$"
  return namespace.len > 0 and rx.match(namespace)

proc compileModList(): JsonNode =
  let apiToken = paramStr(1)
  var client = newHttpClient()
  client.headers["Authorization"] = "Bearer " & apiToken

  # TODO add pagination
  var response = client.get("https://api.github.com/search/repositories?q=topic:animdustry-mod")

  if not response.isOk():
    echo "Failed to fetch data from GitHub API"
    echo "Status: " & response.status
    echo "Body: " & response.body
    quit 1

  let modListJson = parseJson(response.bodyStream)

  # Create mod json object
  var
    parsedModsJson = %* { "updated": $getTime().utc() }
    parsedMods = newJArray()
    modProblems = newJObject()
  
  # Parse all mods
  for modNode in modListJson["items"].getElems():
    let
      repoName = modNode["name"].getStr()
      repoOwner = modNode["owner"]["login"].getStr()
      repoFullName = modNode["full_name"].getStr()
      repoUrl = modNode["html_url"].getStr()
      creationDate = modNode["created_at"].getStr()
      lastUpdate = modNode["updated_at"].getStr()
    
    # Enforce blacklist
    if repoName in repoNameBlacklist:
      echo &"Skipping {repoOwner}/{repoName}: {repoNameBlacklist[repoName]}"
      continue
    if repoOwner in userNameBlacklist:
      echo &"Skipping {repoOwner}/{repoName}: {userNameBlacklist[repoOwner]}"
      continue
    
    echo &"Parsing {repoOwner}/{repoName}"

    # Find mod.json or mod.hjson in repository
    response = client.get(&"https://api.github.com/repos/{repoOwner}/{repoName}/contents/")
    let
      repoContents = parseJson(response.bodyStream)
      modFileIdx = repoContents.getElems()
        .findIndex(x => (x["name"].getStr() in ["mod.json", "mod.hjson"]) and x["type"].getStr() == "file")
    if modFileIdx == -1:
      modProblems.add(modError(repoFullName, false, "Repository does not contain a mod.json or mod.hjson file."))
      continue

    let modFile = repoContents.getElems()[modFileIdx]

    # Download and parse content
    try:
      response = client.get(modFile["url"].getStr())
      let
        modFileContent = base64.decode(parseJson(response.bodyStream)["content"].getStr())
        modFileJson =
          if modFile["name"].getStr().endsWith(".hjson"):
            modFileContent.hjson2json().parseJson()
          else:
            modFileContent.parseJson()
        problems = newJArray()

      # Check for errors
      var err = false

      if not modFileJson["namespace"].getStr().namespaceValid():
        problems.add(modError(repoFullName, false, "Invalid namespace.", &"Namespace must be a valid JavaScript identifier."))
        err = true

      if not modFileJson{"enabled"}.getBool(true):
        problems.add(modError(repoFullName, false, "Mod is not enabled.", &"""Set the 'enabled' field in {modFile["name"]} to true or remove it."""))
        err = true

      for field in ["name", "namespace", "author", "description", "version"]:
        if field notin modFileJson:
          problems.add(modError(repoFullName, false, &"""Missing field '{field}' in {modFile["name"]}."""))
          err = true

      # Check for warnings
      if modFileJson{"debug"}.getBool(false):
        problems.add(modError(repoFullName, true, "Mod is in debug mode.", &"""Set the 'debug' field in {modFile["name"]} to false or remove it."""))
      if "tags" notin modFileJson or modFileJson["tags"].getElems().len < 1:
        problems.add(modError(repoFullName, true, "Mod has no tags.", &"""Add tags to {modFile["name"]} to make it easier to find."""))

      # Check for name conflicts
      for m in parsedMods:
        if m["name"].getStr() == modFileJson["name"].getStr():
          # Resolve conflict based on creation date (older mods have priority)
          if creationDate.parse(timeFormat) > m["creationDate"].getStr().parse(timeFormat):
            problems.add(modError(repoFullName, false, &"""Name conflict with {m["repoName"].getStr()}."""))
            err = true
            break
          else:
            problems.add(modError(m["repoName"].getStr(), true, &"""Name conflict with {repoFullName}."""))
            # Will be replaced by this mod
            break

      # Don't add this mod if there was an error
      if err:
        continue

      # Add additional fields
      modFileJson["repoName"] = newJString(repoFullName)
      modFileJson["repoOwner"] = newJString(repoOwner)
      modFileJson["repoUrl"] = newJString(repoUrl)
      modFileJson["downloadUrl"] = newJString(&"https://api.github.com/repos/{repoOwner}/{repoName}/zipball")
      modFileJson["creationDate"] = newJString(creationDate)

      # Add mod to list
      parsedMods.add(modFileJson)
          
    except CatchableError as e:
      if e is JsonParsingError or e is HjsonParsingError:
        modProblems.add(newJArray(modError(repoFullName, false, &"""Syntax error in {modFile["name"].getStr()}.""", e.msg)))
        continue
      elif e is KeyError:
        modProblems.add(modError(repoFullName, false, &"""Invalid content in {modFile["name"].getStr()}.""", e.msg))
        continue
      else:
        raise

  parsedModsJson["mods"] = parsedMods
  parsedModsJson["problems"] = modProblems

  echo "Writing mod list to mods.json"
  writeFile("mod-list.json", parsedModsJson.pretty())

  return parsedModsJson

# Prevents XSS attacks
proc htmlEscape(str: string): string =
  const escapes = {
    '&':  "&amp;",
    '<':  "&lt;",
    '>':  "&gt;",
    '"':  "&quot;",
    '\'': "&#x27;"
  }.toTable

  var mstr = ""

  for c in str:
    if c in escapes:
      mstr &= escapes[c]
    else:
      mstr &= c
  
  return mstr

proc createMarkdown(modsJson: JsonNode) =
  var
    tocStr = ""
    modListStr = ""
    modProblemsStr = ""

  # Write mod list

  tocStr &= "- [Mod List](#mod-list)\n"

  for modNode in modsJson["mods"].getElems():
    let
      modName = modNode["name"].getStr().htmlEscape()
      modNamespace = modNode["namespace"].getStr() # Already validated
      modDesc = modNode["description"].getStr().htmlEscape()
      modAuthor = modNode["author"].getStr().htmlEscape()
      modVersion = modNode["version"].getStr().htmlEscape()
      modTags = modNode["tags"].getElems().map(x => x.getStr().htmlEscape()).join(", ")

    tocStr &= &"  - [{modName}](#{modNamespace})\n"

    modListStr &= &"""
      <h3 id="{modNamespace}">{modName}</h3>

      **Author:** {modAuthor}

      **Version:** {modNode["version"].getStr()}

      {modDesc}

      <details>
      <summary>Details</summary>
      <ul>
        <li><b>Repository:</b> <a href="{modNode["repoUrl"].getStr()}">{modNode["repoUrl"].getStr()}</a></li>
        <li><b>Download:</b> <a href="{modNode["downloadUrl"].getStr()}">{modNode["downloadUrl"].getStr()}</a></li>
        <li><b>Namespace:</b> {modNamespace}</li>
        <li><b>Tags:</b> {modTags}</li>
        <li><b>Creation Date:</b> {modNode["creationDate"].getStr()}</li>
        <li><b>Last Updated:</b> {modNode["lastUpdate"].getStr()}</li>
      </ul>
      </details>

      [Download]({modNode["downloadUrl"].getStr()}) | [Repository]({modNode["repoUrl"].getStr()})
      """
    # Write errors and warnings

    tocStr &= "- [Errors](#errors)\n"

    for pModName, pMod in modsJson["problems"].getFields():
      let
        repoName = problem["repository"].getStr()
        description = problem["description"].getStr().htmlEscape()
        details = problem["details"].getStr().htmlEscape()
        severity =
          if problem["acceptable"].getBool():
            "warning"
          else:
            "error"

      modErrorsStr &= &"""
        <h3 id="{repoName.replace('/', '-')}">{repoName}</h3>
        <
        """

      # Combine everything
      let output = &"""
        <!-- AUTO-GENERATED MOD LIST -->

        # Mod List

        **Last updated:** {modsJson["updated"].getStr()}

        ## Table of Contents

        {tocStr}

        ## Mods

        {modListStr}

        ## Problems

        {modProblemsStr}"""

    writeFile("mods.md", output)
    return output

when isMainModule:
  let modsJson = compileModList()
  createMarkdown(modsJson)
