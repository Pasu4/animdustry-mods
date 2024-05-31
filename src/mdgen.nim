import os, strutils, strformat, httpclient, hjson, json, tables, times, sugar, sequtils

const
  inTimeFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
  outTimeFormat = "ddd, dd MMM yyyy HH:mm:ss 'UTC'"

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

proc createMarkdown*(modsJson: JsonNode) =
  var
    tocStr = ""
    modListStr = ""
    modProblemsStr = ""

  # Write mod list

  tocStr &= "- [Mods](#mods)\n"

  for modNode in modsJson["mods"].getElems():
    let
      modName = modNode["name"].getStr().htmlEscape()
      modNamespace = modNode["namespace"].getStr() # Already validated
      modDesc = modNode["description"].getStr().htmlEscape()
      modAuthor = modNode["author"].getStr().htmlEscape()
      modVersion = modNode["version"].getStr().htmlEscape()
      modTags = modNode{"tags"}.getElems().map(x => x.getStr().htmlEscape()).join(", ")
      modRepo = modNode["repoName"].getStr()

    tocStr &= &"  - [{modName}](#{modNamespace})\n"

    modListStr &= &"""
<h3 id="{modNamespace}">{modName}</h3>

**Author:** {modAuthor}<br>
**Version:** {modVersion}

{modDesc}

[Download]({modNode["downloadUrl"].getStr()}) | [Repository]({modNode["repoUrl"].getStr()})

<details>
<summary>Details</summary>
<ul>
  <li><b>Repository:</b> <a href="{modNode["repoUrl"].getStr()}">{modNode["repoUrl"].getStr()}</a></li>
  <li><b>Download:</b> <a href="{modNode["downloadUrl"].getStr()}">{modNode["downloadUrl"].getStr()}</a></li>
  <li><b>Namespace:</b> {modNamespace}</li>
  <li><b>Tags:</b> {modTags}</li>
  <li><b>Creation Date:</b> {modNode["creationDate"].getStr().parse(inTimeFormat).format(outTimeFormat)}</li>
  <li><b>Last Updated:</b> {modNode["lastUpdate"].getStr().parse(inTimeFormat).format(outTimeFormat)}</li>
</ul>
</details>
"""
    # Write errors and warnings

    tocStr &= "- [Problems](#problems)\n"

    for pModName, pModArr in modsJson["problems"].getFields():
      tocStr &= &"  - [{modRepo}](#{modRepo.replace('/', '-')})\n"
      modProblemsStr &= &"""
<details>
<summary><span id="{modRepo.replace('/', '-')}"><b>{modRepo}</b></span></summary>
<table>
  <thead>
    <tr>
      <th>Severity</th>
      <th>Description</th>
      <th>Details</th>
    </tr>
  </thead>
  <tbody>
"""

      for problem in pModArr.getElems():
        let
          description = problem["description"].getStr().htmlEscape()
          details = problem["details"].getStr().htmlEscape()
          severity = problem["severity"].getStr()
        
        modProblemsStr &= &"""
<tr>
  <td>{severity}</td>
  <td>{description}</td>
  <td>{details}</td>
</tr>
"""
        
      modProblemsStr &= "</tbody></table></details>"

    # Combine everything
    let output = &"""
<!-- AUTO-GENERATED MOD LIST -->

# Mod List

**Last updated:** {modsJson["updated"].getStr().parse(inTimeFormat).format(outTimeFormat)}

## Table of Contents

{tocStr}

## Mods

{modListStr}

## Problems

{modProblemsStr}"""

    # Write to file
    writeFile("mods.md", output)
