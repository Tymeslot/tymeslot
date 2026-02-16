# Dialyzer ignore warnings for Tymeslot core application
# This file is used when running dialyzer from apps/tymeslot/
#
# For umbrella-level analysis, use the root .dialyzer_ignore.exs

[
  # Ignore missing specs from OTP's xmerl_ucs module
  # These are third-party Erlang standard library warnings we cannot fix
  {"xmerl_ucs.erl", :warn_missing_spec, 58},
  {"xmerl_ucs.erl", :warn_missing_spec, 70},
  {"xmerl_ucs.erl", :warn_missing_spec, 75},
  {"xmerl_ucs.erl", :warn_missing_spec, 84},
  {"xmerl_ucs.erl", :warn_missing_spec, 88},
  {"xmerl_ucs.erl", :warn_missing_spec, 92},
  {"xmerl_ucs.erl", :warn_missing_spec, 108},
  {"xmerl_ucs.erl", :warn_missing_spec, 117},
  {"xmerl_ucs.erl", :warn_missing_spec, 122},
  {"xmerl_ucs.erl", :warn_missing_spec, 125},
  {"xmerl_ucs.erl", :warn_missing_spec, 128},
  {"xmerl_ucs.erl", :warn_missing_spec, 131},
  {"xmerl_ucs.erl", :warn_missing_spec, 134},
  {"xmerl_ucs.erl", :warn_missing_spec, 137},
  {"xmerl_ucs.erl", :warn_missing_spec, 141},
  {"xmerl_ucs.erl", :warn_missing_spec, 144},
  {"xmerl_ucs.erl", :warn_missing_spec, 147},
  {"xmerl_ucs.erl", :warn_missing_spec, 150},
  {"xmerl_ucs.erl", :warn_missing_spec, 153},
  {"xmerl_ucs.erl", :warn_missing_spec, 156},
  {"xmerl_ucs.erl", :warn_missing_spec, 161},
  {"xmerl_ucs.erl", :warn_missing_spec, 164},
  {"xmerl_ucs.erl", :warn_missing_spec, 167},
  {"xmerl_ucs.erl", :warn_missing_spec, 170},
  {"xmerl_ucs.erl", :warn_missing_spec, 173},
  {"xmerl_ucs.erl", :warn_missing_spec, 176},
  {"xmerl_ucs.erl", :warn_missing_spec, 181},
  {"xmerl_ucs.erl", :warn_missing_spec, 184},
  {"xmerl_ucs.erl", :warn_missing_spec, 193},
  {"xmerl_ucs.erl", :warn_missing_spec, 483},
  {"xmerl_ucs.erl", :warn_missing_spec, 523}
]
