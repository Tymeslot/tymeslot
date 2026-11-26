defmodule Tymeslot.Infrastructure.AdminAlerts.AlertTypeProvider do
  @moduledoc """
  A source of admin alert types defined outside Core's own registry.

  A deployment that raises alerts of its own lists its providers under
  `config :tymeslot, :admin_alert_type_providers`. `AlertTypes` answers from
  Core's registry first and then from each provider, so a provider's types are
  categorised, formatted and deduplicated exactly like Core's. A provider may
  not register a type that Core or an earlier provider already registers:
  `AlertTypes.validate_providers!/0` refuses to boot with one.

  `format_message/2` and `dedup_key/2` are only called with a type that
  `registered_types/0` lists, and keep the contracts of `AlertTypes`:

    * `format_message/2` receives metadata already passed through
      `PIIScrubber.scrub/1`, and its result reaches Logger and the persisted
      Oban job args.
    * `dedup_key/2` receives the raw metadata. The key is hashed and stored per
      open dedup window, so changing the key a type produces emails the admin
      again about every incident of that type still open. A type whose message
      carries no per-occurrence detail can return its formatted message.
  """

  @type severity :: :info | :warning | :error
  @type registry :: %{atom() => %{category: String.t(), severity: severity()}}

  @callback registered_types() :: registry()
  @callback format_message(atom(), map()) :: String.t()
  @callback dedup_key(atom(), map()) :: String.t()
end
