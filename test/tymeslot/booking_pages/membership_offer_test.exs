defmodule Tymeslot.BookingPages.MembershipOfferTest do
  @moduledoc """
  A booking page leaves out of the types ticked onto it what the profile's own
  page leaves out: a paid type while its host cannot take payments, and a
  fixed-date type with no date open for registration.
  """

  # Not async: the feature checker is application config.
  use Tymeslot.DataCase, async: false

  @moduletag :profiles
  @moduletag :meeting_types

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.BookingPages

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
    profile = insert(:profile, user: user)
    page = insert(:booking_page, profile: profile)
    insert(:connect_account, user: user, default_currency: "eur", charges_enabled: true)

    %{user: user, page: page}
  end

  defp tick(page, type), do: :ok = BookingPages.set_meeting_type(page, type.id, true)

  defp listed_names(page),
    do: page |> BookingPages.list_meeting_types() |> Enum.map(& &1.name) |> Enum.sort()

  test "a paid type is offered while its host can take payments, and left out once not", ctx do
    paid =
      insert(:meeting_type,
        user: ctx.user,
        name: "Paid Consult",
        payment_required: true,
        price_cents: 5000
      )

    free = insert(:meeting_type, user: ctx.user, name: "Free Call")
    tick(ctx.page, paid)
    tick(ctx.page, free)

    assert listed_names(ctx.page) == ["Free Call", "Paid Consult"]

    setup_config(:tymeslot, :feature_access_checker, DenyPaymentsChecker)

    assert listed_names(ctx.page) == ["Free Call"]
  end

  test "a fixed-date type with no date open for registration is left out", ctx do
    workshop =
      insert(:meeting_type,
        user: ctx.user,
        name: "Workshop",
        max_participants: 3,
        fixed_dates: true
      )

    solo = insert(:meeting_type, user: ctx.user, name: "Solo")
    tick(ctx.page, workshop)
    tick(ctx.page, solo)

    assert listed_names(ctx.page) == ["Solo"]
  end
end
