defmodule TymeslotWeb.Themes.Shared.LiveHelpersTest do
  use Tymeslot.DataCase, async: true

  @moduletag :scheduling

  alias Tymeslot.MeetingTypes
  alias TymeslotWeb.Themes.Shared.LiveHelpers

  # Minimal socket that satisfies handle_schedule_entry's pre-conditions:
  # - username_context is a binary  (private-link guard check)
  # - organizer_profile is nil      (prevents async availability fetch)
  defp schedule_socket(extra_assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            flash: %{},
            username_context: "testuser",
            organizer_user_id: nil,
            organizer_profile: nil,
            meeting_types: [],
            meeting_type: nil,
            user_timezone: nil,
            selected_duration: nil
          },
          extra_assigns
        )
    }
  end

  describe "handle_schedule_entry/2" do
    test "assigns a private meeting type found in pre-loaded meeting_types list" do
      # A private type is excluded from the public list_active_meeting_types query
      # (which filters is_private == false), so the fallback to socket.assigns[:meeting_types]
      # must find it.
      user = insert(:user)

      mt =
        insert(:meeting_type,
          user: user,
          name: "Secret Session",
          is_private: true,
          is_active: true,
          duration_minutes: 45
        )

      slug = MeetingTypes.to_slug(mt)

      socket =
        schedule_socket(%{
          organizer_user_id: user.id,
          meeting_types: [mt]
        })

      result = LiveHelpers.handle_schedule_entry(socket, %{"slug" => slug})

      assert result.assigns.meeting_type.id == mt.id
    end

    test "assigns a public meeting type found via the normal slug lookup" do
      user = insert(:user)

      mt =
        insert(:meeting_type,
          user: user,
          name: "Public Chat",
          is_private: false,
          is_active: true,
          duration_minutes: 30
        )

      slug = MeetingTypes.to_slug(mt)

      # meeting_types list is empty — must be found through the DB query
      socket = schedule_socket(%{organizer_user_id: user.id, meeting_types: []})

      result = LiveHelpers.handle_schedule_entry(socket, %{"slug" => slug})

      assert result.assigns.meeting_type.id == mt.id
    end

    test "does not assign meeting_type when no match is found anywhere" do
      user = insert(:user)
      # Insert a meeting type so has_meeting_types? returns true and no defaults are created
      _other = insert(:meeting_type, user: user, name: "Other", is_active: true)

      socket = schedule_socket(%{organizer_user_id: user.id, meeting_types: []})

      result = LiveHelpers.handle_schedule_entry(socket, %{"slug" => "no-such-type"})

      # With an unmatched slug and a valid username_context, the socket is redirected.
      # The meeting_type assign is NOT set (remains nil from mock).
      assert result.redirected != nil
    end
  end
end
