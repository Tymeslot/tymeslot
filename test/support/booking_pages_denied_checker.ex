defmodule Tymeslot.Test.BookingPagesDeniedChecker do
  @moduledoc """
  A feature access checker for a host whose plan lacks booking pages: it
  refuses `:booking_pages_allowed`, as the managed offering's checker does for
  a free account, and allows everything else. Configured globally, so a test
  using it is `async: false`.
  """

  @behaviour Tymeslot.Features.CheckerBehaviour

  @impl Tymeslot.Features.CheckerBehaviour
  @spec check_access(integer(), atom()) :: :ok | {:error, :insufficient_plan}
  def check_access(_user_id, :booking_pages_allowed), do: {:error, :insufficient_plan}
  def check_access(_user_id, _feature), do: :ok
end
