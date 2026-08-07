defmodule TymeslotWeb.Dashboard.Automation.TelegramCrudJourneyTest do
  @moduledoc """
  The organiser's Telegram configuration journey: connect a bot, edit it,
  switch it off.

  The counterpart to `SlackCrudJourneyTest`, and missing for the same reason.
  `TelegramCompositionTest` covers the surface around the form; the CRUD
  handlers behind it were only ever reached by rendering, never by submitting.

  Telegram's create path has one wrinkle Slack's does not: saving an own-bot
  integration first sends a live test message through `Telegram.test_integration/1`
  and refuses to persist if it fails. That check is the whole point of the
  form — it is what stops an organiser walking away believing notifications are
  configured when the token or chat id is wrong — so both outcomes are pinned
  below. The Telegram API itself is mocked at the HTTP boundary.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :telegram
  @moduletag :automation
  @moduletag :live
  @moduletag :integration

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import Tymeslot.TestFixtures

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.ConfigTestHelpers
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Telegram

  @bot_token "1234567890:ABCdefGHIjklMNOpqrSTUvwxyz123456789"
  @chat_id "100001"

  setup :verify_on_exit!

  setup %{conn: conn} = tags do
    Mox.set_mox_from_context(tags)

    user = create_user_fixture()
    {:ok, user} = UserQueries.mark_onboarding_complete(user)

    ConfigTestHelpers.setup_config(:tymeslot,
      telegram_notifications_allowed: true,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      dashboard_additional_hooks: [],
      feature_placeholder_components: %{}
    )

    {:ok, conn: log_in_user(conn, user), user: user}
  end

  defp stub_telegram_api(response) do
    stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts -> response end)
  end

  defp telegram_ok, do: {:ok, %{status: 200, body: ~s({"ok":true,"result":{}})}}

  defp open_telegram_tab(conn) do
    {:ok, view, _html} = live(conn, "/dashboard/automation")
    view |> element("button", "Telegram") |> render_click()
    view
  end

  # The empty state pushes the event as a JS command while the populated tab
  # uses a plain attribute; match either so the helper works in both states.
  defp open_create_form(view) do
    view |> element("[phx-click*='show_telegram_form']") |> render_click()
  end

  defp edit_button(integration) do
    ~s([phx-click*='show_edit_telegram_form'][phx-click*='"id":#{integration.id}'])
  end

  describe "connecting a Telegram bot" do
    test "a working bot is tested, then persisted and listed", %{conn: conn, user: user} do
      stub_telegram_api(telegram_ok())

      view = open_telegram_tab(conn)
      open_create_form(view)

      view
      |> form("#telegram-form", %{
        "telegram" => %{
          "name" => "Booking Alerts",
          "bot_token" => @bot_token,
          "chat_id" => @chat_id,
          "events" => ["meeting.created"]
        }
      })
      |> render_submit()

      assert [integration] = Telegram.list_integrations(user.id)
      assert integration.name == "Booking Alerts"
      assert integration.events == ["meeting.created"]
      assert integration.is_active

      assert render(view) =~ "Booking Alerts"
    end

    test "a bot that fails its test message is not persisted", %{conn: conn, user: user} do
      # Telegram rejects the token: the organiser must be told, and no
      # half-working integration may be left behind claiming to be active.
      stub_telegram_api(
        {:ok, %{status: 401, body: ~s({"ok":false,"description":"Unauthorized"})}}
      )

      view = open_telegram_tab(conn)
      open_create_form(view)

      view
      |> form("#telegram-form", %{
        "telegram" => %{
          "name" => "Broken Bot",
          "bot_token" => @bot_token,
          "chat_id" => @chat_id,
          "events" => ["meeting.created"]
        }
      })
      |> render_submit()

      assert Telegram.list_integrations(user.id) == []
    end

    test "the bot token is never rendered back to the page", %{conn: conn} do
      stub_telegram_api(telegram_ok())

      view = open_telegram_tab(conn)
      open_create_form(view)

      view
      |> form("#telegram-form", %{
        "telegram" => %{
          "name" => "Secret Bot",
          "bot_token" => @bot_token,
          "chat_id" => @chat_id,
          "events" => ["meeting.created"]
        }
      })
      |> render_submit()

      refute render(view) =~ @bot_token
    end

    test "a submission with no events selected is rejected", %{conn: conn, user: user} do
      stub_telegram_api(telegram_ok())

      view = open_telegram_tab(conn)
      open_create_form(view)

      view
      |> form("#telegram-form", %{
        "telegram" => %{
          "name" => "No Events",
          "bot_token" => @bot_token,
          "chat_id" => @chat_id,
          "events" => []
        }
      })
      |> render_submit()

      assert Telegram.list_integrations(user.id) == []
    end
  end

  describe "editing an existing Telegram integration" do
    setup %{user: user} do
      integration =
        insert(:telegram_integration,
          user: user,
          name: "Original Bot",
          bot_mode: "own",
          bot_token_encrypted: Encryption.encrypt(@bot_token),
          chat_id: @chat_id,
          events: ["meeting.created"],
          is_active: true
        )

      %{integration: integration}
    end

    test "the edit form opens prefilled with the current name", %{
      conn: conn,
      integration: integration
    } do
      view = open_telegram_tab(conn)

      view |> element(edit_button(integration)) |> render_click()

      assert render(view) =~ "Original Bot"
    end

    test "renaming and re-subscribing persists both changes", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      stub_telegram_api(telegram_ok())

      view = open_telegram_tab(conn)
      view |> element(edit_button(integration)) |> render_click()

      view
      |> form("#telegram-form", %{
        "telegram" => %{
          "name" => "Renamed Bot",
          "bot_token" => "",
          "chat_id" => @chat_id,
          "events" => ["meeting.cancelled", "meeting.rescheduled"]
        }
      })
      |> render_submit()

      assert [updated] = Telegram.list_integrations(user.id)
      assert updated.name == "Renamed Bot"
      assert Enum.sort(updated.events) == ["meeting.cancelled", "meeting.rescheduled"]
    end

    test "leaving the bot token blank keeps the stored credential", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      stub_telegram_api(telegram_ok())

      {:ok, original} = Telegram.get_integration(integration.id, user.id)

      refute is_nil(original.bot_token_encrypted),
             "setup must store a credential, or the comparison below is nil == nil"

      view = open_telegram_tab(conn)
      view |> element(edit_button(integration)) |> render_click()

      view
      |> form("#telegram-form", %{
        "telegram" => %{
          "name" => "Kept Token",
          "bot_token" => "",
          "chat_id" => @chat_id,
          "events" => ["meeting.created"]
        }
      })
      |> render_submit()

      {:ok, reloaded} = Telegram.get_integration(integration.id, user.id)

      assert reloaded.name == "Kept Token"

      assert reloaded.bot_token_encrypted == original.bot_token_encrypted,
             "an edit that leaves the token field blank must not blank the stored credential"
    end
  end

  describe "switching an integration off" do
    setup %{user: user} do
      integration =
        insert(:telegram_integration,
          user: user,
          name: "Toggle Me",
          bot_mode: "own",
          bot_token_encrypted: Encryption.encrypt(@bot_token),
          chat_id: @chat_id,
          events: ["meeting.created"],
          is_active: true
        )

      %{integration: integration}
    end

    test "toggling active off stops it firing but keeps the row", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      view = open_telegram_tab(conn)

      view
      |> element("[phx-click='toggle_telegram'][phx-value-id='#{integration.id}']")
      |> render_click()

      {:ok, reloaded} = Telegram.get_integration(integration.id, user.id)

      refute reloaded.is_active
      assert reloaded.name == "Toggle Me", "toggling off must not delete the integration"
    end
  end
end
