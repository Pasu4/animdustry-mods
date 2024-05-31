import os, strutils, strformat, httpclient, hjson, json, tables, times, sugar, base64, sequtils

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

proc modError(description: string, details = description): JsonNode =
  return %* { "description": description, "details": details, "severity": "Error" }

proc modWarning(description: string, details = description): JsonNode =
  return %* { "description": description, "details": details, "severity": "Warning" }

proc namespaceValid(namespace: string): bool =
  # Namespace must be a valid JavaScript identifier
  return namespace.len > 0 and (namespace[0].isAlphaAscii() or namespace[0] == '_') and namespace.all(c => c.isAlphaNumeric() or c == '_')

proc compileModList*(): JsonNode =
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
      modProblems.add(modError("Repository does not contain a mod.json or mod.hjson file."))
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
        problems.add(modError("Invalid namespace.", &"Namespace must be a valid JavaScript identifier."))
        err = true

      if not modFileJson{"enabled"}.getBool(true):
        problems.add(modError("Mod is not enabled.", &"""Set the 'enabled' field in {modFile["name"]} to true or remove it."""))
        err = true

      for field in ["name", "namespace", "author", "description", "version"]:
        if field notin modFileJson:
          problems.add(modError(&"""Missing field '{field}' in {modFile["name"]}."""))
          err = true

      # Check for warnings
      if modFileJson{"debug"}.getBool(false):
        problems.add(modWarning("Mod is in debug mode.", &"""Set the 'debug' field in {modFile["name"]} to false or remove it."""))
      if "tags" notin modFileJson or modFileJson["tags"].getElems().len < 1:
        problems.add(modWarning("Mod has no tags.", &"""Add tags to {modFile["name"]} to make it easier to find."""))

      # Check for name conflicts
      for m in parsedMods:
        if m["name"].getStr() == modFileJson["name"].getStr():
          # Resolve conflict based on creation date (older mods have priority)
          if creationDate.parse(timeFormat) > m["creationDate"].getStr().parse(timeFormat):
            problems.add(modError(&"""Name conflict with {m["repoName"].getStr()}."""))
            err = true
            break
          else:
            modProblems[m["repoName"].getStr()].add(modError(&"""Name conflict with {repoFullName}."""))
            # Will be replaced by this mod
            break
      
      # Add problems to modProblems
      if problems.len > 0:
        modProblems.add(repoFullName, problems)

      # Don't add this mod if there was an error
      if err:
        continue

      # Add additional fields
      modFileJson["repoName"] = newJString(repoFullName)
      modFileJson["repoOwner"] = newJString(repoOwner)
      modFileJson["repoUrl"] = newJString(repoUrl)
      modFileJson["downloadUrl"] = newJString(&"https://api.github.com/repos/{repoOwner}/{repoName}/zipball")
      modFileJson["creationDate"] = newJString(creationDate)
      modFileJson["lastUpdate"] = newJString(lastUpdate)

      # Add mod to list
      parsedMods.add(modFileJson)
          
    except CatchableError as e:
      if e is JsonParsingError or e is HjsonParsingError:
        var a = newJArray()
        a.add(modError(&"""Syntax error in {modFile["name"].getStr()}.""", e.msg))
        modProblems.add(repoFullName, a)
        continue
      elif e is KeyError:
        var a = newJArray()
        a.add(modError(&"""Invalid content in {modFile["name"].getStr()}.""", e.msg))
        modProblems.add(repoFullName, a)
        continue
      else:
        raise

  parsedModsJson["mods"] = parsedMods
  parsedModsJson["problems"] = modProblems

  echo "Writing mod list to mod-list.json"
  writeFile("mod-list.json", parsedModsJson.pretty())

  return parsedModsJson
