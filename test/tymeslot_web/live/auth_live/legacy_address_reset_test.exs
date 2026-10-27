defmodule TymeslotWeb.AuthLive.LegacyAddressResetTest do
  use TymeslotWeb.LiveCase, async: false

  @moduletag :auth
  @moduletag :live

  import Tymeslot.Factory

  # An account whose stored address predates the email format rules must be
  # able to reset its password from the form, without being told as it types
  # that its own address is invalid.
  test "the reset form accepts a stored address the format rules would refuse", %{conn: conn} do
    address = ~s("legacy"@example.com)
    insert(:user, email: address)
    {:ok, view, _html} = live(conn, ~p"/auth/reset-password")

    html =
      view
      |> element("#reset-password-form input[name='email']")
      |> render_change(%{"email" => address})

    refute html =~ "Email format is invalid"

    view
    |> form("#reset-password-form", %{"email" => address})
    |> render_submit()

    assert_patch(view, ~p"/auth/reset-password-sent")
  end
end
