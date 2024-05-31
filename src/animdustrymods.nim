import getapi, mdgen

when isMainModule:
  let modsJson = compileModList()
  createMarkdown(modsJson)
  echo "Done"
