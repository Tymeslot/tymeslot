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
  {"lib/tymeslot_web/gettext.ex", :call_without_opaque},

  # `Tymeslot.Test.TagTaxonomy` lives in `test/support`, so it exists in the
  # `:test` build `mix test.affected` runs in (see `preferred_envs` in mix.exs)
  # and not in the `:dev` build Dialyzer analyses; the module loads it from
  # source there. Same reasoning as its `@compile {:no_warn_undefined, TagTaxonomy}`.
  {"dev_support/tooling/test_affected/workspace.ex", :unknown_function},

  # `:xmerl` is left out of the PLT (`plt_ignore_apps` in mix.exs), so its SAX
  # parser is invisible to Dialyzer. It ships with OTP and is a runtime
  # dependency of sweet_xml, so the call resolves in every build.
  {"lib/tymeslot/integrations/calendar/utils/safe_xml.ex", :unknown_function}
]
