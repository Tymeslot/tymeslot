defmodule TymeslotWeb.Themes.Shared.PaymentReturnLive.ExtensionsTest do
  @moduledoc """
  The payment return pages sit in the booking page's shell but are not
  booking-page impressions, so they render none of the configured theme
  extensions (on the managed instance, the branding banner and the
  analytics beacon), for each shipped theme. Not async: the extensions are application-wide
  configuration.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :payments
  @moduletag :themes

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.Profiles
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Test.BrandingFooterStub
  alias TymeslotWeb.ThemeTestMatrix

  setup do
    old = Application.get_env(:tymeslot, :theme_extensions)
    Application.put_env(:tymeslot, :theme_extensions, [{BrandingFooterStub, :banner}])
    on_exit(fn -> Application.put_env(:tymeslot, :theme_extensions, old) end)
  end

  for id <- ThemeTestMatrix.ids() do
    {:ok, key} = Catalog.id_to_key(id)
    slug = Atom.to_string(key)

    test "#{slug}: neither return page renders the theme extensions", %{conn: conn} do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      {:ok, _profile} = Profiles.update_booking_theme(profile, unquote(id))
      meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

      insert(:booking_payment,
        meeting: meeting,
        host_user_id: user.id,
        status: "pending",
        stripe_checkout_session_id: "cs_TEST"
      )

      paths = [
        "/themes/#{unquote(slug)}/payment-processing/#{meeting.id}?session_id=cs_TEST",
        "/themes/#{unquote(slug)}/payment-cancelled/#{meeting.id}"
      ]

      for path <- paths do
        {:ok, view, html} = live(conn, path)
        assert has_element?(view, "[data-booker-root] .booker-card h1")
        refute html =~ "branding-footer"
      end
    end
  end
end
