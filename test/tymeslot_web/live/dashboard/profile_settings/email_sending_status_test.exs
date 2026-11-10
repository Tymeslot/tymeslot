defmodule TymeslotWeb.Dashboard.ProfileSettings.EmailSendingStatusTest do
  @moduledoc "Verifies recorded SMTP status without a separate destructive form refresh action."

  use TymeslotWeb.LiveCase, async: false

  @moduletag :emails
  @moduletag :live

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.EmailSendingTestHelpers

  alias Tymeslot.EmailSending
  alias Tymeslot.EmailSending.Sender
  alias Tymeslot.Repo
  alias TymeslotWeb.Dashboard.ProfileSettings.EmailSending.ErrorMessages

  @attrs %{
    "host" => "smtp.example.com",
    "security" => "starttls",
    "username" => "status-fixture-account",
    "password" => "status-fixture-secret",
    "from_address" => "bookings@example.com",
    "from_name" => "Appointments"
  }

  setup :setup_dashboard_user

  setup do
    with_config(:tymeslot, user_smtp_enabled: true)
    :ok
  end

  test "saved identities have no refresh action and obsolete clicks preserve unsaved edits",
       context do
    original = saved_smtp_settings(context.user, @attrs, enabled: true)
    {:ok, view, html} = open_smtp_settings(context.conn)
    refute has_element?(view, "#smtp-refresh")
    refute html =~ "Refresh status"
    assert has_element?(view, "#smtp-test-save")
    assert has_element?(view, "#smtp-delete")

    view
    |> form("#user-smtp-form", smtp: Map.put(@attrs, "from_name", "Unsaved appointments"))
    |> render_change()

    {:ok, document} = Floki.parse_document(render(view))

    credential_ids =
      document |> Floki.find("input[data-smtp-credential]") |> Floki.attribute("id")

    assert length(credential_ids) == 2

    # A page opened before an upgrade may still send the removed event. It must
    # not reload settings and silently discard that page's in-progress input.
    view |> with_target("#email-sending-settings") |> render_click("refresh_smtp")

    assert has_element?(view, "#smtp-from-name[value='Unsaved appointments']")
    assert Enum.all?(credential_ids, &has_element?(view, "##{&1}"))
    refute has_element?(view, "#app-flash-group-info")
    assert Repo.reload!(original) == original
  end

  test "reopening the profile shows the latest recorded delivery failure", context do
    original = saved_smtp_settings(context.user, @attrs, enabled: true)
    {:ok, view, _html} = open_smtp_settings(context.conn)
    refute has_element?(view, "#smtp-delivery-error")

    assert :ok =
             EmailSending.record_delivery_outcome(
               Sender.from_settings(original),
               {:error, :authentication_failed}
             )

    before_reopen = Repo.reload!(original)
    {:ok, reopened, _html} = open_smtp_settings(context.conn)

    assert has_element?(
             reopened,
             "#smtp-delivery-error",
             ErrorMessages.message(:authentication_failed)
           )

    assert has_element?(reopened, "#smtp-status[data-state='attention']")
    refute has_element?(reopened, "#smtp-refresh")
    assert Repo.reload!(original) == before_reopen
  end
end
