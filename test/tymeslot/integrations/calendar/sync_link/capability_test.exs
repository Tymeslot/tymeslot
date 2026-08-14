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

  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.SyncLink.Capability

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
                recurrence: false
              }},
             {:outlook,
              %{
                mirror_target: true,
                target_calendar_choice: true,
                per_event_colour: false,
                recurrence: false
              }},
             {:ics_url,
              %{
                mirror_target: false,
                target_calendar_choice: false,
                per_event_colour: false,
                recurrence: false
              }},
             # `:demo` backs the public demonstration calendar rather than one
             # an organiser owns, so it answers exactly as an unknown provider
             # does rather than being a fixture a link could write into.
             {:demo,
              %{
                mirror_target: false,
                target_calendar_choice: false,
                per_event_colour: false,
                recurrence: false
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
               {provider,
                %{
                  mirror_target: true,
                  target_calendar_choice: false,
                  per_event_colour: false,
                  recurrence: false
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
    for feature <- [:mirror_target, :target_calendar_choice, :per_event_colour, :recurrence] do
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
    # Deliberately false for everyone, Google included: the row exists so the
    # next stage flips one cell rather than introducing the concept alongside
    # the feature. A test that only checked "Google is false" would pass for
    # the wrong reason once Google is enabled, so the claim asserted is the
    # stronger one — nobody has it yet.
    test "no provider supports recurrence yet" do
      for provider <- ProviderConfig.provider_constraint_list() do
        refute Capability.supports?(provider, :recurrence),
               "#{provider} unexpectedly claims :recurrence support"
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
