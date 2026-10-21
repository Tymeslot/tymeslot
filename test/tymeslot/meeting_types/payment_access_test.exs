defmodule Tymeslot.MeetingTypes.PaymentAccessTest do
  @moduledoc """
  A paid meeting type is offered to bookers, on the listing and by its
  direct link, only while its host can take payments: a charges-enabled
  Stripe account and a plan that includes payments. Free types are offered
  either way.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :meeting_types
  @moduletag :payments

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.MeetingTypes

  defmodule DenyPaymentsChecker do
    @moduledoc false
    @behaviour Tymeslot.Features.CheckerBehaviour

    @impl Tymeslot.Features.CheckerBehaviour
    def check_access(_user_id, :meeting_payments), do: {:error, :insufficient_plan}
    def check_access(_user_id, _feature), do: :ok
  end

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true
    )

    user = insert(:user)
    insert(:connect_account, user: user, default_currency: "eur", charges_enabled: true)

    paid =
      insert(:meeting_type,
        user: user,
        name: "Paid Consult",
        payment_required: true,
        price_cents: 5000
      )

    free = insert(:meeting_type, user: user, name: "Free Call")

    %{user: user, paid: paid, free: free}
  end

  defp public_ids(user), do: user.id |> MeetingTypes.get_public_meeting_types() |> ids()
  defp ids(types), do: types |> Enum.map(& &1.id) |> Enum.sort()

  test "offers the paid type while the host can take payments",
       %{user: user, paid: paid, free: free} do
    assert public_ids(user) == ids([paid, free])
    assert MeetingTypes.find_by_slug(user.id, "paid-consult").id == paid.id
  end

  test "leaves the paid type out once the host's plan stops including payments",
       %{user: user, free: free} do
    setup_config(:tymeslot, :feature_access_checker, DenyPaymentsChecker)

    assert public_ids(user) == [free.id]
    assert MeetingTypes.find_by_slug(user.id, "paid-consult") == nil
    assert MeetingTypes.find_by_slug(user.id, "free-call").id == free.id
  end
end
