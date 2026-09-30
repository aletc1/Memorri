import Foundation

let usage = """
memorri-eval: score Memorri's analysis against a golden set

usage: memorri-eval <command> [options]

commands:
  generate-synthetic   draw the synthetic golden cases
  run                  run the pipeline over the cases and print the scores
  compare <a> <b>      compare two saved reports
  sweep-size           run the set at several picture sizes

Nothing is implemented yet.
"""
print(usage)
