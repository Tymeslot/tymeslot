defmodule Tymeslot.Integrations.Calendar.SyncLink.Capability do
  @moduledoc """
  What a calendar provider can do when it stands at either end of a sync link.

  ## Why this is one module rather than four decisions

  Every asymmetry mirroring depends on was already handled correctly, and each
  in its own place: the ICS-target refusal lived in
  `CalendarSyncLinkSchema.validate_target_writable/1` *and* again as a worker
  discard; the CalDAV calendar-id rule lived in
  `CalendarSyncLinkSchema.clear_calendar_id_for_caldav_target/1` *and* again in
  the hub component; the Google-only colour lived in `Engine.colour_target/1`.
  Four facts, six sites, no single place to ask "what does this link's target
  actually support?".

  The cost is paid when a fifth asymmetry arrives: whoever adds it has to
  rediscover all six sites first, and a reader who wants the answer has to read
  four modules to assemble it. So the facts move here and the sites ask. Nothing
  about *what* is answered changes — this module was introduced as a pure
  refactor of the answers that were already being given.

  ## Strings are the form callers actually hold

  `supports?/2` takes the provider as a string as readily as an atom, because
  `calendar_integrations.provider` is a string column and every caller reaches
  this question holding that string — off the row, or off a form parameter.
  `ProviderConfig.caldav_based?/1` is atom-only with a silent `false` catch-all,
  which is not a hypothetical trap: handed `"nextcloud"` it answers `false`, and
  a CalDAV branch gated on it never fires. That already cost one debugging
  session on this feature. Both forms are answered here, and the test table
  asserts every provider/feature pair in both.

  An unrecognised provider — a typo, a `nil`, a provider retired from the
  registry while its integration rows remain — answers `false` for every
  feature. That is the safe direction in all four cases: a refused link, a
  hidden picker and an unpainted placeholder are all recoverable, while a write
  to an unknown target is an event on a calendar nobody asked for.

  `:demo` answers `false` everywhere. It backs the public demonstration
  calendar rather than one an organiser owns, and a link naming it as a target
  would write busy blocks into something shared.

  `:debug` does **not**, and the two are worth telling apart. It implements the
  full `Provider` behaviour against an in-memory store, which makes it the only
  way to drive this engine end to end without standing up HTTP mocks. The
  registry already keeps it out of production through `@dev_only_providers`, so
  refusing it here would add no safety and would remove the cheapest test path
  the feature has.

  ## The table

  | Feature | google | outlook | caldav family | ics_url |
  | --- | --- | --- | --- | --- |
  | `:mirror_target` | yes | yes | yes | no |
  | `:target_calendar_choice` | yes | yes | no | no |
  | `:per_event_colour` | yes | no | no | no |
  | `:recurrence` | no | no | no | no |

  `:mirror_target` is false for ICS alone: a subscription is a published feed
  and `Ics.Provider.create_event/2` answers `{:error, :read_only}`, so a link
  naming one as its target could never write anything.

  `:target_calendar_choice` is false for the CalDAV family because those
  providers ignore a `:calendar_id` in the payload entirely and always write to
  the primary calendar path. It is false for ICS too, but only as a consequence
  of ICS not being a target at all — nothing consults it there, since the
  `:mirror_target` refusal comes first.

  `:per_event_colour` is true for Google alone. `patch_event_colour/4` lives on
  `Google.GoogleCalendarApi` and is not part of the shared `Provider` behaviour,
  so there is no polymorphic call to make for anyone else.

  ## The recurrence row is a starting position, not a finding

  `:recurrence` is false for **every** provider here, Google included, and
  nothing consults it yet — `Eligibility.recurring?/1` still refuses a recurring
  source outright, deliberately and unchanged. The row exists now so that
  enabling recurrence later flips one cell in this table rather than
  introducing the concept along with the feature.

  Google's cell is false only because the series master cannot yet be fetched:
  under `singleEvents=true` the cached row is an *instance* whose RRULE cannot
  be trusted, and `GoogleCalendarApi` has no single-event GET to read the master
  with. That is the next stage's work, not a claim about Google.

  Outlook and CalDAV are false as a **starting position rather than a verified
  finding**. Outlook has a structured `recurrence` object rather than an RRULE
  and there is already a `RecurrenceConverter` for the inbound direction;
  CalDAV takes an RRULE natively. Both are plausible later. Neither is claimed
  here, and this table is where that claim gets made when someone verifies it.
  """

  alias Tymeslot.Integrations.Calendar.ProviderConfig

  @typedoc """
  One thing a provider may or may not be able to do as the target of a sync
  link.

  - `:mirror_target` — can receive a placeholder write at all.
  - `:target_calendar_choice` — honours a `:calendar_id` in the event payload,
    so the organiser's choice of which calendar to write to means something.
  - `:per_event_colour` — has a per-event colour reachable from the mirror
    path.
  - `:recurrence` — can be handed a recurring series as one event. False for
    everyone today; see the moduledoc.
  """
  @type feature :: :mirror_target | :target_calendar_choice | :per_event_colour | :recurrence

  @caldav_providers ProviderConfig.caldav_based_providers()
  @caldav_provider_strings ProviderConfig.caldav_based_provider_strings()

  @doc """
  Whether `provider` supports `feature`.

  Accepts the provider as an atom or as the string form that comes off
  `calendar_integrations.provider`. Anything unrecognised — an unknown string,
  `nil`, a dev-only provider — answers `false` for every feature, which is the
  safe direction at all four call sites.

      iex> alias Tymeslot.Integrations.Calendar.SyncLink.Capability
      iex> Capability.supports?("nextcloud", :mirror_target)
      true
      iex> Capability.supports?("nextcloud", :target_calendar_choice)
      false
      iex> Capability.supports?(:ics_url, :mirror_target)
      false
      iex> Capability.supports?("google", :per_event_colour)
      true
      iex> Capability.supports?(:google, :recurrence)
      false
  """
  @spec supports?(String.t() | atom() | any(), feature()) :: boolean()
  def supports?(provider, :mirror_target),
    do: known?(provider) and not ProviderConfig.subscription?(provider)

  def supports?(provider, :target_calendar_choice),
    do: supports?(provider, :mirror_target) and not caldav?(provider)

  def supports?(provider, :per_event_colour), do: provider in [:google, "google"]

  # False for everyone in this stage, on purpose — see the moduledoc. The clause
  # exists so the next stage changes one cell rather than adding a concept.
  def supports?(_provider, :recurrence), do: false

  # `parse_known/1` rather than `parse/1`, so the answer does not turn on a
  # runtime toggle. A link is configured once and written to for years; a
  # provider switched off in config must not silently make every existing link
  # to it unwritable, which is the outcome a toggle-aware check would produce.
  #
  # `:demo` is excluded. It is a fixture for the public demonstration calendar,
  # not a calendar anyone owns, and a link naming it as a target would write
  # busy blocks into something shared.
  #
  # `:debug` is NOT excluded, and the distinction matters. It implements the
  # full `Provider` behaviour — create, update and delete against an in-memory
  # store — and is the only way to exercise this engine end to end without
  # standing up HTTP mocks for a real provider. It is already kept out of
  # production by the registry itself (`@dev_only_providers`), so excluding it
  # here would buy no safety and would cost the cheapest test path there is.
  defp known?(provider) do
    case ProviderConfig.parse_known(provider) do
      {:ok, parsed} -> parsed != :demo
      {:error, :unknown} -> false
    end
  end

  defp caldav?(provider) when is_atom(provider), do: provider in @caldav_providers
  defp caldav?(provider) when is_binary(provider), do: provider in @caldav_provider_strings
  defp caldav?(_provider), do: false
end
