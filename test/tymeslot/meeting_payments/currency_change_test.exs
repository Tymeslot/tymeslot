defmodule Tymeslot.MeetingPayments.CurrencyChangeTest do
  use Tymeslot.DataCase, async: true

  @moduletag :payments

  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingTypes.MeetingTypeQueries

  setup do
    user = insert(:user)
    account = insert(:connect_account, user: user, default_currency: "eur", charges_enabled: true)
    paid = insert(:meeting_type, user: user, payment_required: true, price_cents: 5000)

    %{user: user, account: account, paid: paid}
  end

  defp currency_of(user), do: ConnectAccountQueries.live_for_user(user.id).default_currency

  defp price_of(meeting_type),
    do: MeetingTypeQueries.get_meeting_type!(meeting_type.id).price_cents

  describe "change_default_currency/2" do
    test "switches the currency and resets the host's paid prices", ctx do
      assert {:ok, :reset} = MeetingPayments.change_default_currency(ctx.account, "gbp")

      assert currency_of(ctx.user) == "gbp"
      assert price_of(ctx.paid) == nil
    end

    test "leaves everything alone when the currency is already the account's", ctx do
      assert {:ok, :unchanged} = MeetingPayments.change_default_currency(ctx.account, "eur")

      assert price_of(ctx.paid) == 5000
    end

    test "refuses a currency outside the allowlist", ctx do
      assert {:error, :unsupported_currency} =
               MeetingPayments.change_default_currency(ctx.account, "jpy")

      assert currency_of(ctx.user) == "eur"
      assert price_of(ctx.paid) == 5000
    end

    test "refuses while a booking awaits payment, so its price keeps its currency", ctx do
      insert(:meeting, organizer_user_id: ctx.user.id, status: "awaiting_payment")

      assert {:error, :pending_payments_exist} =
               MeetingPayments.change_default_currency(ctx.account, "gbp")

      assert currency_of(ctx.user) == "eur"
      assert price_of(ctx.paid) == 5000
    end

    test "reads the account as it is now, not the copy the caller holds", ctx do
      # The dashboard holds the account it loaded; a change made since (in
      # another tab, say) is what the comparison must see.
      {:ok, _changed} = MeetingPayments.change_default_currency(ctx.account, "gbp")

      assert {:ok, :unchanged} = MeetingPayments.change_default_currency(ctx.account, "gbp")
    end
  end
end
