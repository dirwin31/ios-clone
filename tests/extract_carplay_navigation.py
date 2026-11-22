from pathlib import Path
import sys

source = Path("GalaxyBluetooth/CarPlaySceneDelegate.swift").read_text()
def declaration(prefix):
  start = source.index("    private " + prefix)
  opening = source.index("{", start)
  depth = 1
  end = opening + 1
  while depth:
    if source[end] == "{":
      depth += 1
    if source[end] == "}":
      depth -= 1
    end += 1
  return source[start:end].replace("private ", "", 1)

stub = Path("tests/CarPlayNavigationRegression.swift").read_text()
members = ("func pushTemplate(", "func popTemplate(", "final class SettingsPageState", "struct NumericAdjustment", "func displayedSettingValue(", "func descriptionLines(")
Path(sys.argv[1]).write_text(stub.replace("__PRODUCTION_METHODS__", "\n".join(map(declaration, members))))
