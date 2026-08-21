defmodule Tymeslot.Integrations.Calendar.DisplayHelpersTest do
  @moduledoc """
  `integration_label/1`, the disambiguator for two integrations of one
  provider.

  The case that motivates it: connecting two Google accounts stores the same
  literal name for both, because `google_oauth_helper.ex` hardcodes
  `"Google Calendar"` and nothing downstream ever revisits it. The account
  those rows differ in is already stored; only the label ignored it.

  These tests pin the fallback order rather than any one provider, because the
  disambiguating column differs per family: OAuth has an email, the CalDAV
  family has `base_url||username`, and an ICS subscription has only a feed
  origin — its `provider_account_id` is a SHA-256 digest and would be noise.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :utils

  alias Tymeslot.Integrations.Calendar.DisplayHelpers

  defp integration(attrs) do
    Map.merge(
      %{
        name: "Google Calendar",
        provider: "google",
        provider_account_email: nil,
        provider_account_id: nil,
        base_url: nil
      },
      attrs
    )
  end

  describe "integration_label/1" do
    test "qualifies the name with the account email when there is one" do
      label =
        DisplayHelpers.integration_label(
          integration(%{provider_account_email: "organiser@example.com"})
        )

      assert label == "Google Calendar — organiser@example.com"
    end

    test "distinguishes two accounts sharing one hardcoded provider name" do
      first =
        DisplayHelpers.integration_label(
          integration(%{provider_account_email: "organiser@example.com"})
        )

      second =
        DisplayHelpers.integration_label(
          integration(%{provider_account_email: "second@example.com"})
        )

      refute first == second
    end

    test "keeps a name the organiser chose and still qualifies it" do
      # Renaming is what an organiser does *because* the labels collide, so the
      # qualifier has to survive it — otherwise renaming one of two identical
      # calendars re-hides the account it belongs to.
      label =
        DisplayHelpers.integration_label(
          integration(%{name: "Work", provider_account_email: "organiser@example.com"})
        )

      assert label == "Work — organiser@example.com"
    end

    test "falls back to the CalDAV account, dropping the password-bearing half" do
      # `provider_account_id` is `base_url||username` for this family. The
      # username identifies the account; the URL is already implied by the
      # provider name, so showing the whole pair is noise.
      label =
        DisplayHelpers.integration_label(
          integration(%{
            name: "My Nextcloud",
            provider: "nextcloud",
            provider_account_id: "https://cloud.example.com/remote.php/dav||alice",
            base_url: "https://cloud.example.com/remote.php/dav"
          })
        )

      assert label == "My Nextcloud — alice"
    end

    test "falls back to the feed origin for a subscription" do
      # An ICS `provider_account_id` is a SHA-256 hex digest of the feed URL —
      # unique, and useless to read. The origin is what the dashboard already
      # shows for these rows.
      label =
        DisplayHelpers.integration_label(
          integration(%{
            name: "Team holidays",
            provider: "ics_url",
            provider_account_id: String.duplicate("a", 64),
            base_url: "https://calendar.google.com"
          })
        )

      assert label == "Team holidays — calendar.google.com"
    end

    test "returns the bare name when nothing disambiguates it" do
      assert DisplayHelpers.integration_label(integration(%{name: "My CalDAV"})) == "My CalDAV"
    end

    test "does not repeat a qualifier the name already carries" do
      # A CalDAV name is typed by the organiser, who may well have typed the
      # account into it. Appending it again reads as a bug.
      label =
        DisplayHelpers.integration_label(
          integration(%{
            name: "alice",
            provider: "nextcloud",
            provider_account_id: "https://cloud.example.com||alice"
          })
        )

      assert label == "alice"
    end

    test "still qualifies a name that merely contains the account as a substring" do
      # A short username inside an unrelated word is a coincidence, not a
      # repetition. Suppressing on a bare substring match drops the qualifier
      # exactly where two calendars might collide.
      label =
        DisplayHelpers.integration_label(
          integration(%{
            name: "Personal",
            provider: "nextcloud",
            provider_account_id: "https://cloud.example.com||al"
          })
        )

      assert label == "Personal — al"
    end

    test "names a row whose name is missing rather than rendering nothing" do
      # `name` is `NOT NULL` in the schema, so this is defensive — but a label
      # is a rendering primitive and returning "" would silently blank a row.
      assert DisplayHelpers.integration_label(integration(%{name: nil})) == "Calendar"

      assert DisplayHelpers.integration_label(integration(%{name: "   "})) == "Calendar"
    end
  end

  describe "integration_name/1 and integration_qualifier/1" do
    # The grid stacks these on two lines, so it needs the halves rather than the
    # composed label. They are the same two values `integration_label/1` joins,
    # exposed rather than recomputed: a second implementation of "which column
    # disambiguates this provider" would drift from the first the next time a
    # provider family is added, and the grid would disagree with every dropdown.
    test "answer the two halves the label is composed from" do
      integration = integration(%{provider_account_email: "organiser@example.com"})

      assert DisplayHelpers.integration_name(integration) == "Google Calendar"
      assert DisplayHelpers.integration_qualifier(integration) == "organiser@example.com"
    end

    test "compose back into the label for every provider family" do
      # The invariant that keeps the grid and the dropdowns naming one calendar
      # identically. Asserted per family because each takes a different clause
      # through `qualifier/1`.
      for integration <- [
            integration(%{provider_account_email: "organiser@example.com"}),
            integration(%{
              name: "My Nextcloud",
              provider: "nextcloud",
              provider_account_id: "https://cloud.example.com||alice"
            }),
            integration(%{
              name: "Team holidays",
              provider: "ics_url",
              base_url: "https://feeds.example.com"
            })
          ] do
        name = DisplayHelpers.integration_name(integration)
        qualifier = DisplayHelpers.integration_qualifier(integration)

        assert DisplayHelpers.integration_label(integration) == "#{name} — #{qualifier}"
      end
    end

    test "answer nil for a qualifier the name already carries" do
      # `integration_label/1` suppresses the repetition by dropping the
      # qualifier, so the split has to report the same suppression — otherwise
      # the grid prints a second line the label deliberately omits.
      integration =
        integration(%{
          name: "alice",
          provider: "nextcloud",
          provider_account_id: "https://cloud.example.com||alice"
        })

      assert DisplayHelpers.integration_name(integration) == "alice"
      assert DisplayHelpers.integration_qualifier(integration) == nil
    end

    test "answer nil for a qualifier no column can supply" do
      # An OAuth row with no email recorded. The name still has to render.
      integration = integration(%{name: "Work", provider_account_email: nil})

      assert DisplayHelpers.integration_name(integration) == "Work"
      assert DisplayHelpers.integration_qualifier(integration) == nil
    end

    test "fall back to the placeholder name when the name is missing" do
      assert DisplayHelpers.integration_name(integration(%{name: nil})) == "Calendar"
      assert DisplayHelpers.integration_name(integration(%{name: "   "})) == "Calendar"
    end
  end
end
