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
  import Tymeslot.TestHelpers.Eventually

  alias Tymeslot.ConfigTestHelpers
  alias Tymeslot.Onboarding.OnboardingQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Telegram

  @bot_token "1234567890:ABCdefGHIjklMNOpqrSTUvwxyz123456789"
  @chat_id "100001"

  setup :verify_on_exit!

  setup %{conn: conn} = tags do
    Mox.set_mox_from_context(tags)

    user = create_user_fixture()
    {:ok, user} = OnboardingQueries.mark_onboarding_complete(user)

    ConfigTestHelpers.setup_config(:tymeslot,
      telegram_notifications_allowed: true,
      telegram_shared_bot: false,
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

  defp blur_field(view, field, value) do
    view
    |> element("#telegram-form input[name='telegram[#{field}]']")
    |> render_blur(%{"value" => value})
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

    # `render_submit/1` ignores `disabled`, so the button's attribute is what
    # tells whether an organiser can submit at all.
    test "the submit button stays disabled until a bot token is typed", %{conn: conn} do
      view = open_telegram_tab(conn)
      open_create_form(view)

      blur_field(view, "name", "Booking Alerts")
      blur_field(view, "chat_id", @chat_id)

      view
      |> element(~s(#telegram-form input[type=checkbox][value="meeting.created"]))
      |> render_click()

      assert has_element?(view, "#telegram-form button[type=submit][disabled]")

      blur_field(view, "bot_token", @bot_token)

      assert has_element?(view, "#telegram-form button[type=submit]:not([disabled])")
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
      # Empty required fields reach the server, which answers in the form.
      assert has_element?(view, "#telegram-form[novalidate]")
    end

    test "the submit button is enabled without retyping the bot token", %{
      conn: conn,
      integration: integration
    } do
      view = open_telegram_tab(conn)
      view |> element(edit_button(integration)) |> render_click()

      assert has_element?(view, "#telegram-form input[name='telegram[bot_token]']")
      assert has_element?(view, "#telegram-form button[type=submit]:not([disabled])")
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

  describe "with the shared bot enabled" do
    # In shared mode the only proof that a chat belongs to the organiser is
    # the `/start <token>` deep link the bot receives. The form renders no
    # chat id field, but a LiveView event carries whatever params the client
    # sends, so these submissions forge one.
    setup do
      ConfigTestHelpers.setup_config(:tymeslot, telegram_shared_bot: true)
      :ok
    end

    test "a chat id forged into the setup form is not linked", %{conn: conn, user: user} do
      view = open_telegram_tab(conn)
      open_create_form(view)
      [stub] = Telegram.list_integrations(user.id)

      # Advance the wizard to the details step without the bot linking a chat.
      send(view.pid, {:telegram_linked, stub.id, "987654321"})
      eventually(fn -> assert render(view) =~ "Integration Details" end)

      view
      |> element("#telegram-form")
      |> render_submit(%{
        "telegram" => %{
          "name" => "Forged Chat",
          "chat_id" => "-1009999999999",
          "events" => ["meeting.created"]
        }
      })

      assert {:ok, saved} = Telegram.get_integration(stub.id, user.id)
      assert saved.name == "Forged Chat"
      assert saved.chat_id == nil
      assert saved.linked_at == nil
    end

    test "a chat id forged into the edit form leaves the linked chat alone", %{
      conn: conn,
      user: user
    } do
      integration =
        insert(:telegram_integration,
          user: user,
          name: "Linked Chat",
          bot_mode: "shared",
          bot_token_encrypted: nil,
          chat_id: @chat_id,
          events: ["meeting.created"]
        )

      view = open_telegram_tab(conn)
      view |> element(edit_button(integration)) |> render_click()

      view
      |> element("#telegram-form")
      |> render_submit(%{
        "telegram" => %{
          "name" => "Renamed Chat",
          "chat_id" => "-1009999999999",
          "events" => ["meeting.created"]
        }
      })

      assert {:ok, saved} = Telegram.get_integration(integration.id, user.id)
      assert saved.name == "Renamed Chat"
      assert saved.chat_id == @chat_id
    end

    test "editing an own-bot integration keeps it on its own bot", %{conn: conn, user: user} do
      integration =
        insert(:telegram_integration,
          user: user,
          name: "Own Bot",
          bot_mode: "own",
          bot_token_encrypted: Encryption.encrypt(@bot_token),
          chat_id: @chat_id,
          events: ["meeting.created"]
        )

      view = open_telegram_tab(conn)
      view |> element(edit_button(integration)) |> render_click()

      view
      |> element("#telegram-form")
      |> render_submit(%{
        "telegram" => %{"name" => "Renamed Own Bot", "events" => ["meeting.created"]}
      })

      assert {:ok, saved} = Telegram.get_integration(integration.id, user.id)
      assert saved.name == "Renamed Own Bot"
      assert saved.bot_mode == "own"
      assert saved.chat_id == @chat_id
    end
  end

  describe "editing follows the integration's own bot, not the installation's" do
    # The installation's bot mode decides how a *new* integration links its
    # chat. An existing integration keeps the mode it was created with, so
    # its edit form must validate and render against that mode instead.

    test "an own-bot integration's token and chat stay editable with the shared bot on", %{
      conn: conn,
      user: user
    } do
      ConfigTestHelpers.setup_config(:tymeslot, telegram_shared_bot: true)

      integration =
        insert(:telegram_integration,
          user: user,
          name: "Own Bot",
          bot_mode: "own",
          bot_token_encrypted: Encryption.encrypt(@bot_token),
          chat_id: @chat_id,
          events: ["meeting.created"]
        )

      new_token = "9876543210:ZYXwvuTSRqpoNMLkjiHGFedcba987654321"

      view = open_telegram_tab(conn)
      view |> element(edit_button(integration)) |> render_click()

      assert has_element?(view, "#telegram-form input[name='telegram[bot_token]']")
      assert has_element?(view, "#telegram-form input[name='telegram[chat_id]']")

      view
      |> element("#telegram-form")
      |> render_submit(%{
        "telegram" => %{
          "name" => "Own Bot",
          "bot_token" => new_token,
          "chat_id" => "200002",
          "events" => ["meeting.created"]
        }
      })

      assert {:ok, saved} = Telegram.get_integration(integration.id, user.id)
      assert saved.bot_mode == "own"
      assert saved.chat_id == "200002"
      assert Encryption.decrypt(saved.bot_token_encrypted) == new_token
    end

    test "a shared-bot integration can be renamed with the shared bot off", %{
      conn: conn,
      user: user
    } do
      integration = insert_shared_integration(user)

      view = open_telegram_tab(conn)
      view |> element(edit_button(integration)) |> render_click()

      refute has_element?(view, "#telegram-form input[name='telegram[chat_id]']")

      view
      |> element("#telegram-form")
      |> render_submit(%{
        "telegram" => %{"name" => "Renamed Chat", "events" => ["meeting.created"]}
      })

      assert {:ok, saved} = Telegram.get_integration(integration.id, user.id)
      assert saved.name == "Renamed Chat"
      assert saved.chat_id == @chat_id
    end

    test "a chat id forged into a shared-bot edit is ignored with the shared bot off", %{
      conn: conn,
      user: user
    } do
      integration = insert_shared_integration(user)

      view = open_telegram_tab(conn)
      view |> element(edit_button(integration)) |> render_click()

      view
      |> element("#telegram-form")
      |> render_submit(%{
        "telegram" => %{
          "name" => "Forged Chat",
          "chat_id" => "-1009999999999",
          "events" => ["meeting.created"]
        }
      })

      assert {:ok, saved} = Telegram.get_integration(integration.id, user.id)
      assert saved.name == "Forged Chat"
      assert saved.chat_id == @chat_id
    end

    defp insert_shared_integration(user) do
      insert(:telegram_integration,
        user: user,
        name: "Linked Chat",
        bot_mode: "shared",
        bot_token_encrypted: nil,
        chat_id: @chat_id,
        events: ["meeting.created"]
      )
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
