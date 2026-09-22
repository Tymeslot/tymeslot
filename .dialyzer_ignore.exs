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
  # and not in the `:dev` build Dialyzer analyses. Same reasoning as the
  # `@compile {:no_warn_undefined, TagTaxonomy}` on the task itself.
  {"lib/mix/tasks/test.affected.ex", :unknown_function},

  # gen_smtp types a `:network_failure` reason as `{:error, atom()}`, but its
  # implicit-TLS path hands back the TLS alert whole,
  # `{:error, {:tls_alert, {:unexpected_message, _}}}`, which
  # `test/tymeslot/mailer/smtp_tls_transport_test.exs` asserts against a real
  # relay. Matching on that shape is what lets the adapter retry a handshake
  # refused for the missing middlebox record, so the clause stays and the
  # contract is what is wrong.
  {"lib/tymeslot/mailer/smtp_adapter.ex", :pattern_match}
]
