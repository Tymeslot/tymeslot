defmodule Tymeslot.Integrations.Calendar.SyncLink.CapabilityTest do
  @moduledoc """
  The provider capability table, asserted cell by cell.

  This is the one place the four asymmetries mirroring depends on are written
  down, so it is the one place they can be read back — every provider against
  every feature, rather than a sample. A table that is only partly asserted is
  a table whose unasserted half drifts.

  Every pair is asserted **twice**, once with the provider as an atom and once
  as the string that actually comes off `calendar_integrations.provider`. The
  string form is not a courtesy: `ProviderConfig.caldav_based?/1` is atom-only
  with a silent `false` catch-all, and handed `"nextcloud"` it answers `false`
  — a CalDAV branch gated on it never fires, which already cost one debugging
  session on this feature. Asserting only the atom form is how that bug passes
  its tests.
  """
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :sync_links

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.SyncLink.Capability
  alias Tymeslot.Integrations.Calendar.SyncLink.RecurringSeries

  # The examples in `supports?/2`'s `@doc` are the first thing a reader of the
  # module sees. Running them is what keeps them from drifting into a lie.
  doctest Capability, import: true

  @caldav_family ~w(caldav radicale nextcloud zimbra mailbox_org apple baikal)a

  # provider => %{feature => expected}
  @table Map.new(
           [
             {:google,
              %{
                mirror_target: true,
                target_calendar_choice: true,
                per_event_colour: true,
                recurrence: true,
                series_lookup: true
              }},
             {:outlook,
              %{
                mirror_target: true,
                target_calendar_choice: true,
                per_event_colour: false,
                recurrence: false,
                series_lookup: true
              }},
             {:ics_url,
              %{
                mirror_target: false,
                target_calendar_choice: false,
                per_event_colour: false,
                recurrence: false,
                series_lookup: false
              }},
             # `:demo` backs the public demonstration calendar rather than one
             # an organiser owns, so it answers exactly as an unknown provider
             # does rather than being a fixture a link could write into.
             {:demo,
              %{
                mirror_target: false,
                target_calendar_choice: false,
                per_event_colour: false,
                recurrence: false,
                series_lookup: false
              }},
             # `:debug` is deliberately NOT grouped with `:demo`. It implements
             # create, update and delete against an in-memory store, which makes
             # it the only way to drive the mirror engine end to end without HTTP
             # mocks. The registry already keeps it out of production, so
             # refusing it here would cost the cheapest test path and buy
             # nothing. It has no per-event colour, so it declines that one.
             {:debug,
              %{
                mirror_target: true,
                target_calendar_choice: true,
                per_event_colour: false,
                recurrence: false
              }}
           ] ++
             for provider <- @caldav_family do
               # `recurrence: true` and `series_lookup: false` together, which
               # looks contradictory and is not: the two rows are the two ends of
               # one mirror. A CalDAV calendar can *receive* a series — verified
               # against a live Radicale, which stored the RRULE and the EXDATE
               # and expanded the result to four occurrences instead of five —
               # but it can never *supply* one, because `ICalNormaliser` expands
               # a CalDAV series locally into correctly-timed one-offs that carry
               # no master to look up.
               {provider,
                %{
                  mirror_target: true,
                  target_calendar_choice: false,
                  per_event_colour: false,
                  recurrence: true,
                  series_lookup: false
                }}
             end
         )

  describe "supports?/2 — the capability table" do
    for {provider, features} <- @table, {feature, expected} <- features do
      test "#{provider} #{if expected, do: "supports", else: "does not support"} #{feature}, as an atom" do
        assert Capability.supports?(unquote(provider), unquote(feature)) == unquote(expected)
      end

      test "#{provider} #{if expected, do: "supports", else: "does not support"} #{feature}, as a string" do
        assert Capability.supports?(unquote(Atom.to_string(provider)), unquote(feature)) ==
                 unquote(expected)
      end
    end
  end

  describe "supports?/2 — coverage of the provider registry" do
    # A provider added to `ProviderConfig` and not to the table above would
    # silently answer `false` for everything, which is safe but invisible: its
    # links would never be writable and nothing would say why. This fails the
    # moment the registry grows past what the table describes.
    test "every registered provider has an asserted row" do
      registered =
        MapSet.new(ProviderConfig.provider_constraint_list(), &String.to_existing_atom/1)

      asserted = @table |> Map.keys() |> MapSet.new()

      assert MapSet.difference(registered, asserted) == MapSet.new()
    end
  end

  describe "supports?/2 — unknown providers" do
    # The safe direction at all four call sites: a refused link, a hidden
    # picker and an unpainted placeholder are recoverable, while a write to an
    # unrecognised target is an event on a calendar nobody asked for.
    for feature <- [
          :mirror_target,
          :target_calendar_choice,
          :per_event_colour,
          :recurrence,
          :series_lookup
        ] do
      test "an unrecognised provider does not support #{feature}" do
        refute Capability.supports?("fastmail", unquote(feature))
        refute Capability.supports?(:fastmail, unquote(feature))
        refute Capability.supports?(nil, unquote(feature))
        refute Capability.supports?("", unquote(feature))
        refute Capability.supports?(42, unquote(feature))
      end
    end
  end

  describe "supports?/2 — :recurrence in this stage" do
    # Google and the CalDAV family, and the claim asserted is still the
    # exclusive one. A recurring source is mirrored as a single recurring
    # placeholder the target expands itself, so a provider whose cell flips
    # without that expansion being verified would receive a series it renders
    # wrongly — and, worse, one whose cancelled occurrences block time forever.
    # Enabling anyone else has to break this test and bring evidence.
    #
    # The CalDAV cells were flipped on a live Radicale round-trip: the stored
    # VEVENT carried both the RRULE and the EXDATE, and the server expanded the
    # series to four occurrences rather than five. See the `Capability`
    # moduledoc, and `radicale_recurrence_integration_test.exs` for the run.
    test "google and the caldav family support recurrence, and no one else does" do
      assert Capability.supports?(:google, :recurrence)
      assert Capability.supports?("google", :recurrence)

      for provider <- ProviderConfig.caldav_based_provider_strings() do
        assert Capability.supports?(provider, :recurrence),
               "#{provider} should claim :recurrence — the family shares one write path"
      end

      for provider <- ProviderConfig.caldav_based_providers() do
        assert Capability.supports?(provider, :recurrence),
               "the atom form must agree with the string form"
      end

      # Outlook is the interesting refusal. `EventMapper.add_recurrence/2` reads
      # `:recurrence_rule` and nothing else, so a series mirrored there arrives
      # with its cancellations discarded — the same defect the CalDAV path had
      # until `Properties.build_exception_lines/1`, and it has not been fixed or
      # measured for Graph.
      refute Capability.supports?(:outlook, :recurrence)
      refute Capability.supports?("outlook", :recurrence)

      allowed = ["google" | ProviderConfig.caldav_based_provider_strings()]

      for provider <- ProviderConfig.provider_constraint_list(), provider not in allowed do
        refute Capability.supports?(provider, :recurrence),
               "#{provider} unexpectedly claims :recurrence support"
      end
    end
  end

  describe "supports?/2 — :series_lookup is the source side" do
    # The mirror of the `:recurrence` block above, and deliberately a separate
    # question. `:recurrence` says a **target** can be handed a whole series;
    # this says a **source** can have its series master fetched, which is what
    # `SyncLink.RecurringSeries` needs before any rule exists to hand anyone.
    # Both are Google-only today and that is a coincidence of this stage, not
    # one fact: either cell can move without the other.
    test "google and outlook support series lookup, and no other provider does" do
      for provider <- [:google, "google", :outlook, "outlook"] do
        assert Capability.supports?(provider, :series_lookup)
      end

      # The CalDAV family is the interesting refusal, and it is not a gap
      # waiting to be filled. A CalDAV row is not an expanded instance pointing
      # at a master: `ICalNormaliser.expand_event/3` expands the series locally,
      # `build_uid/1` gives every occurrence its own uid, and `resolve_timing/1`
      # times each from its own occurrence — so each cached row is already a
      # correctly-timed one-off with nothing to look up. `recurring_event_id` is
      # never set for the family, so no row can reach the lookup anyway.
      for provider <- ProviderConfig.provider_constraint_list(),
          provider not in ~w(google outlook) do
        refute Capability.supports?(provider, :series_lookup),
               "#{provider} unexpectedly claims :series_lookup support"
      end
    end

    # The anti-drift assertion, and the reason this feature key exists rather
    # than a second provider list beside `RecurringSeries.api_module/1`.
    #
    # Two lists that must agree are two lists that will eventually disagree, and
    # the failure is silent in the worst direction: `Eligibility` admits a
    # source it believes resolvable, `RecurringSeries` answers
    # `{:skip, :provider_has_no_series_lookup}`, and the mirror is discarded
    # forever with no placeholder written and the organiser's time left
    # bookable. So there is one list — this table — and the module derives its
    # own refusal from it. This test is what pins that they cannot part
    # company: for every registered provider, "capability says yes" and
    # "an API module exists to ask" are the same answer.
    test "a provider has a series-lookup API module exactly when the table says so" do
      for provider <- ProviderConfig.provider_constraint_list() do
        integration = %CalendarIntegrationSchema{provider: provider}

        assert RecurringSeries.api_module(integration) != nil ==
                 Capability.supports?(provider, :series_lookup),
               """
               #{provider} disagrees between Capability.supports?(:series_lookup) and \
               RecurringSeries.api_module/1. These must be one fact, not two lists.
               """
      end
    end
  end

  describe "supports?/2 — independence from runtime toggles" do
    # A link is configured once and written to for years. A provider switched
    # off in config must not make every existing link to it silently
    # unwritable — the placeholders would simply stop appearing, and the first
    # the organiser hears of it is a double booking. So the answer is derived
    # from the static registry (`parse_known/1`) rather than the toggle-aware
    # `parse/1`, and the whole DB constraint list is asserted here rather than
    # the currently-enabled list.
    test "a provider outside the enabled set is still judged on what it is" do
      # `:debug` is absent from the enabled list in the test environment and
      # still answers `true` for `:mirror_target`. That is the distinction this
      # pins: the answer describes what a provider *is*, not whether a runtime
      # toggle currently admits it. Were it keyed on the toggle, every existing
      # link to a temporarily-disabled provider would go quietly unwritable and
      # the first anyone would hear of it is a double booking.
      refute :debug in ProviderConfig.all_providers_with_dev()
      assert Capability.supports?("debug", :mirror_target)

      for provider <- ProviderConfig.provider_constraint_list(),
          provider not in ~w(ics_url demo) do
        assert Capability.supports?(provider, :mirror_target),
               "#{provider} lost :mirror_target — is the answer keyed on a runtime toggle?"
      end
    end
  end
end
