defmodule TymeslotWeb.Dashboard.Automation.TelegramCompositionTest do
  @moduledoc """
  Composition tests for the Telegram integration LiveComponent.

  The existing `telegram_event_handlers_test.exs` exhaustively covers
  empty-state rendering, form open/close, edit, toggle, delete, feature
  access denial, and the shared-bot wizard lifecycle. This file fills
  the remaining gaps that require real external-seam stitching:

    * own-bot create where the Telegram API call inside
      `Telegram.test_integration/1` fails — the error must reach the
      user as a flash and not land a half-created row;
    * shared-bot `refresh_telegram_link` — cycles the deep link and
      clears the expired state;
    * `webhook_write` rate-limit exhaustion on create — the limiter
      blocks before the Telegram API is ever called.

  Dropped from the plan with rationale:

    * `disconnect_telegram` on own-bot integration — no UI surface
      renders the disconnect button for own-bot mode. The template at
      `telegram_card.ex:193` gates it on
      `@integration.bot_mode == "shared" && @integration.chat_id`,
      so the `{:error, :own_bot_mode}` branch at
      `state_handlers.ex:88` is unreachable from a real click.
      Reaching it would require forging the event, which is a unit
      test of the defensive guard rather than a composition test.
    * `reconnect_telegram` on disconnected integration — covered
      end-to-end by the shared-bot wizard flow in
      `telegram_event_handlers_test.exs:281` (close deletes stub) and
      `:312` (link advances wizard). The reconnect handler's code
      path is the same `refresh_link_token` machinery the refresh
      test below already pins; the additional DB shape
      (`chat_id = nil`) is a trivial `Telegram.reconnect_integration/1`
      step covered in the Telegram context unit tests.
    * `update_telegram` with `telegram_form_data` nil — plan already
      marked this as a defensive guard for states the UI cannot emit.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :automation
  @moduletag :telegram
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.TestFixtures

  alias Plug.Test, as: PlugTest
  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.ConfigTestHelpers
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Telegram

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = create_user_fixture()
    {:ok, user} = UserQueries.mark_onboarding_complete(user)

    ConfigTestHelpers.setup_config(:tymeslot,
      telegram_notifications_allowed: true,
      telegram_shared_bot: false,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      dashboard_additional_hooks: [],
      feature_placeholder_components: %{}
    )

    conn = conn |> PlugTest.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  defp open_telegram_tab(view) do
    view |> element("button", "Telegram") |> render_click()
    render(view)
  end

  # Valid-format own-bot token; rejected by InputValidation if malformed.
  @valid_bot_token "1234567890:ABCdefGHIjklMNOpqrSTUvwxyz123456789"

  describe "create_telegram — own-bot API failure" do
    @tag :capture_log
    test "surfaces a flash and does not persist when the Telegram API call fails",
         %{conn: conn, user: user} do
      # Route the Telegram API probe to a failing HTTP response so
      # `Telegram.test_integration/1` returns `{:error, reason}` — the
      # shape the handler must surface as "Test failed: ..." without
      # ever creating the integration row.
      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :timeout}}
      end)

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("button", "Add Telegram Account") |> render_click()

      # The events checkbox uses a phx-click that maintains server
      # state; without it the events validator rejects the submit
      # before ever reaching test_integration. Click one to stage it.
      view
      |> element("input[name='telegram[events][]'][value='meeting.created']")
      |> render_click()

      view
      |> form("#telegram-form", %{
        "telegram" => %{
          "name" => "My Bot",
          "bot_token" => @valid_bot_token,
          "chat_id" => "-1001234567890"
        }
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Test failed"
      refute html =~ "Telegram integration created"
      assert Telegram.list_integrations(user.id) == []
    end
  end

  describe "refresh_telegram_link — shared-bot wizard" do
    setup do
      ConfigTestHelpers.setup_config(:tymeslot, telegram_shared_bot: true)
      :ok
    end

    @tag :capture_log
    test "regenerates the deep link and clears the expired state",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("button", "Add Telegram Account") |> render_click()
      [stub] = Telegram.list_integrations(user.id)
      initial_token = stub.link_token
      assert is_binary(initial_token)

      # Force the expired state so the "Generate New Link" button
      # renders — that is the only UI surface that fires
      # `refresh_telegram_link`.
      send(view.pid, {:telegram_link_expired, stub.id})

      eventually(fn ->
        assert render(view) =~ "Link Expired"
      end)

      view |> element("button", "Generate New Link") |> render_click()

      html = render(view)
      refute html =~ "Link Expired"
      assert html =~ "Connect Telegram"

      # The DB-visible outcome: the link token was rotated. A
      # regression in the handler that forgot to rotate (or forgot to
      # persist) would leave the old token in place.
      [refreshed] = Telegram.list_integrations(user.id)
      assert is_binary(refreshed.link_token)
      refute refreshed.link_token == initial_token
    end
  end

  describe "create_telegram — rate limit hit" do
    @tag :capture_log
    test "blocks the Telegram API call and surfaces a flash when the write limit is exhausted",
         %{conn: conn, user: user} do
      # Exhaust the webhook-write bucket (30 per 30 minutes) so the
      # next create attempt trips the limiter before reaching the
      # Telegram API.
      Enum.each(1..30, fn _i ->
        :ok = RateLimiter.check_webhook_write_rate_limit(user.id)
      end)

      # Seed a call to the mock so an accidental Telegram API hit
      # would fail the expectation instead of silently passing.
      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        flunk("HTTP request should be skipped when rate-limited")
      end)

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("button", "Add Telegram Account") |> render_click()

      view
      |> element("input[name='telegram[events][]'][value='meeting.created']")
      |> render_click()

      view
      |> form("#telegram-form", %{
        "telegram" => %{
          "name" => "Rate-limited Bot",
          "bot_token" => @valid_bot_token,
          "chat_id" => "-1001234567890"
        }
      })
      |> render_submit()

      html = render(view)
      assert html =~ "limit of 30"
      refute html =~ "Telegram integration created"
      assert Telegram.list_integrations(user.id) == []
    end
  end
end
