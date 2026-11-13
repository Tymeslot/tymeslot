defmodule Tymeslot.Webhooks.TestWebhookInactiveTest do
  use Tymeslot.DataCase, async: true

  @moduletag :webhooks

  import Mox

  alias Tymeslot.Webhooks

  setup :verify_on_exit!

  test "sends nothing for a webhook switched off" do
    webhook = insert(:webhook, is_active: false)
    expect(Tymeslot.HTTPClientMock, :post, 0, fn _url, _body, _headers, _opts -> :unused end)

    assert {:error, :webhook_inactive} = Webhooks.test_webhook(webhook.user_id, webhook.id)
  end
end
