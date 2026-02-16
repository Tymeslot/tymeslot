# ExCoveralls configuration
# Exclude test support files and generated code from coverage reports

[
  skip_files: [
    # Test support files - these are test infrastructure, not production code
    ~r/test\/support/,

    # Generated Phoenix files
    ~r/_build/,
    ~r/deps/,
    ~r/priv/,
    ~r/node_modules/
  ],

  # Optional: Set minimum coverage thresholds
  # minimum_coverage: 80
]
