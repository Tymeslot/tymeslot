defmodule TymeslotWeb.Dashboard.MeetingTypeDuplicateLiveTest do
  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :live

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.CustomFields.FieldDefinition
  alias Tymeslot.MeetingTypes

  setup :setup_dashboard_user

  setup do
    setup_config(:tymeslot, feature_access_checker: Tymeslot.Features.DefaultAccessChecker)
    :ok
  end

  test "duplicating a type opens the switched-off copy, which saves under a new name", %{
    conn: conn,
    user: user
  } do
    source =
      insert(:meeting_type, user: user, name: "Discovery Call", duration_minutes: 45)

    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("[phx-click='duplicate_type'][phx-value-id='#{source.id}']")
    |> render_click()

    copy = Enum.find(MeetingTypes.get_all_meeting_types(user.id), &(&1.id != source.id))
    assert copy.name == "Discovery Call (copy)"
    assert copy.duration_minutes == 45
    assert copy.is_active == false

    # The copy, not the source, is open in the editor.
    assert has_element?(view, ~s|input[name="meeting_type[name]"][value="Discovery Call (copy)"]|)
    assert render(view) =~ "Meeting type duplicated and switched off"

    view
    |> element(~s|input[name="meeting_type[name]"]|)
    |> render_change(%{"meeting_type" => %{"name" => "Follow-up Call"}})

    assert MeetingTypes.get_meeting_type(copy.id, user.id).name == "Follow-up Call"
    assert MeetingTypes.get_meeting_type(source.id, user.id).name == "Discovery Call"

    view |> element("button", "Done") |> render_click()

    html = render(view)
    assert html =~ "Discovery Call"
    assert html =~ "Follow-up Call"
  end

  test "a refused copy says why and adds nothing", %{conn: conn, user: user} do
    setup_config(:tymeslot, feature_access_checker: __MODULE__.DenyQuestionsChecker)

    source =
      insert(:meeting_type,
        user: user,
        name: "Intake",
        custom_fields: [
          %FieldDefinition{id: "company", type: "short_text", label: "Company", position: 0}
        ]
      )

    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("[phx-click='duplicate_type'][phx-value-id='#{source.id}']")
    |> render_click()

    assert render(view) =~ "your current plan does not include"
    assert [%{id: id}] = MeetingTypes.get_all_meeting_types(user.id)
    assert id == source.id
    refute has_element?(view, ~s|input[name="meeting_type[name]"]|)
  end

  defmodule DenyQuestionsChecker do
    @behaviour Tymeslot.Features.CheckerBehaviour
    @impl Tymeslot.Features.CheckerBehaviour
    def check_access(_user_id, :custom_questions_allowed), do: {:error, :insufficient_plan}
    def check_access(_user_id, _feature), do: :ok
  end
end
