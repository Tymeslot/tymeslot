[
  # Add entries here to suppress specific Dialyzer warnings.
  #
  # Format options:
  #   {"file.ex", :warning_type, line}   - suppress by file + type + line
  #   {"file.ex", :warning_type}          - suppress by file + type
  #   {"file.ex"}                         - suppress all warnings in file
  #   ~r/regex pattern/                   - suppress by matching short description

  # False positives: `use Gettext.Backend` generates calls to Gettext.Plural.plural/2
  # that pass Expo.PluralForms structs containing an opaque plural_ast() field.
  # Dialyzer cannot see through the opaque type boundary introduced by Expo.
  {"lib/tymeslot_web/gettext.ex", :call_without_opaque}
]
