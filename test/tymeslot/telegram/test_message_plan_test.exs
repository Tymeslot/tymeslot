defmodule Tymeslot.Telegram.TestMessagePlanTest do
  use Tymeslot.DataCase, async: false

  @moduletag :telegram

  import Mox
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Telegram
  alias Tymeslot.Telegram.TelegramIntegrationSchema
  alias Tymeslot.Test.ProcessAccessChecker

  setup :verify_on_exit!

  test "a test message is refused, sending nothing, while the plan doesn't include automations" do
    setup_config(:tymeslot,
      feature_access_checker: ProcessAccessChecker,
      telegram_notifications_allowed: true,
      telegram_shared_bot: false,
      http_client_module: Tymeslot.HTTPClientMock
    )

    ProcessAccessChecker.answer({:error, :insufficient_plan})
    expect(Tymeslot.HTTPClientMock, :post, 0, fn _url, _body, _headers, _opts -> :unused end)

    # Saved, or not yet saved and naming its owner, as the create form's test does.
    assert {:error, :insufficient_plan} = Telegram.test_integration(insert(:telegram_integration))

    assert {:error, :insufficient_plan} =
             Telegram.test_integration(%TelegramIntegrationSchema{
               user_id: insert(:user).id,
               bot_mode: "own",
               bot_token: "1234567890:ABCdefGHIjklMNOpqrSTUvwxyz123456789",
               chat_id: "42"
             })
  end
end
