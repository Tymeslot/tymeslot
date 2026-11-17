defmodule Tymeslot.Integrations.Calendar.CalendarIntegrationActivationQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries
  @moduletag :security

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationActivationQueries

  describe "toggle_active/1 — reactivation conflicts" do
    test "returns {:error, :duplicate_account} instead of raising when the conflicting active row's credentials cannot be decrypted" do
      user = insert(:user)

      # Undecryptable bytes stand in for a credential whose key is genuinely
      # gone (e.g. after a SECRET_KEY_BASE rotation). The reactivation check
      # only needs to know this row exists, never its credentials.
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        provider_account_id: "acct-1",
        is_active: true,
        username_encrypted: :crypto.strong_rand_bytes(40),
        password_encrypted: :crypto.strong_rand_bytes(40)
      )

      dormant =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          provider_account_id: "acct-1",
          is_active: false
        )

      assert {:error, :duplicate_account} =
               CalendarIntegrationActivationQueries.toggle_active(dormant)
    end

    test "returns {:error, :duplicate_account} for a legacy null-account row whose conflicting active row can't be decrypted" do
      user = insert(:user)

      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        provider_account_id: nil,
        is_active: true,
        username_encrypted: :crypto.strong_rand_bytes(40),
        password_encrypted: :crypto.strong_rand_bytes(40)
      )

      dormant =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          provider_account_id: nil,
          is_active: false
        )

      assert {:error, :duplicate_account} =
               CalendarIntegrationActivationQueries.toggle_active(dormant)
    end
  end
end
