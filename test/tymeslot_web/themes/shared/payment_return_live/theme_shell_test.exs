defmodule TymeslotWeb.Themes.Shared.PaymentReturnLive.ThemeShellTest do
  @moduledoc """
  One pair of LiveViews serves the payment return pages for every theme. For
  each theme in the matrix: Stripe's return URLs route to the shared pages,
  and a paid booking lands on pages that load that theme's own stylesheet
  and class, never another theme's.
  """

  use TymeslotWeb.ConnCase, async: true

  @moduletag :payments
  @moduletag :themes
  @moduletag :integration

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Shared.PaymentReturnLive.{Cancelled, Processing}
  alias TymeslotWeb.ThemeTestMatrix

  @slugs Enum.map(ThemeTestMatrix.registered_ids(), fn id ->
           {:ok, key} = Catalog.id_to_key(id)
           {id, Atom.to_string(key)}
         end)

  test "the matrix is not empty" do
    assert ThemeTestMatrix.registered_ids() != []
  end

  for {theme_id, slug} <- @slugs do
    describe "#{slug}" do
      setup do
        user = insert(:user)
        {:ok, profile} = Profiles.get_or_create_profile(user.id)
        {:ok, profile} = Profiles.update_profile(profile, %{booking_theme: unquote(theme_id)})
        meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

        insert(:booking_payment,
          meeting: meeting,
          host_user_id: user.id,
          stripe_checkout_session_id: "cs_TEST"
        )

        %{meeting: meeting, profile: profile}
      end

      test "Stripe's return URLs route to the shared pages" do
        assert route_module("/themes/#{unquote(slug)}/payment-processing/m-1") == Processing
        assert route_module("/themes/#{unquote(slug)}/payment-cancelled/m-1") == Cancelled
      end

      test "the processing page loads the theme's own stylesheet",
           %{conn: conn, meeting: meeting} do
        html =
          conn
          |> get("/themes/#{unquote(slug)}/payment-processing/#{meeting.id}?session_id=cs_TEST")
          |> html_response(200)

        assert_theme_stylesheet(html, unquote(slug))
        assert_theme_shell(html, unquote(slug), "processing")
      end

      test "the cancelled page loads the theme's own stylesheet",
           %{conn: conn, meeting: meeting} do
        html =
          conn
          |> get("/themes/#{unquote(slug)}/payment-cancelled/#{meeting.id}")
          |> html_response(200)

        assert_theme_stylesheet(html, unquote(slug))
        assert_theme_shell(html, unquote(slug), "cancelled")
      end

      test "the connected processing page shows the shared body",
           %{conn: conn, meeting: meeting} do
        {:ok, _view, html} =
          live(
            conn,
            "/themes/#{unquote(slug)}/payment-processing/#{meeting.id}?session_id=cs_TEST"
          )

        assert html =~ "Confirming your payment"
      end

      test "both connected pages carry the organiser's customised palette",
           %{conn: conn, meeting: meeting, profile: profile} do
        customization =
          insert(:theme_customization,
            profile: profile,
            theme_id: unquote(theme_id),
            custom_palette_seed: "#c2410c"
          )

        primary =
          ThemeCustomizations.tokens(unquote(theme_id), customization).vars["--theme-primary"]

        refute primary ==
                 ThemeCustomizations.tokens(unquote(theme_id), nil).vars["--theme-primary"]

        processing =
          "/themes/#{unquote(slug)}/payment-processing/#{meeting.id}?session_id=cs_TEST"

        cancelled = "/themes/#{unquote(slug)}/payment-cancelled/#{meeting.id}"

        for path <- [processing, cancelled] do
          {:ok, _view, html} = live(conn, path)
          assert_primary(html, primary)
        end
      end

      if ThemeTestMatrix.fetch!(theme_id).fixture do
        test "a locale change keeps the attendee on the payment page",
             %{conn: conn, meeting: meeting} do
          path = "/themes/#{unquote(slug)}/payment-processing/#{meeting.id}?session_id=cs_TEST"
          {:ok, view, html} = live(conn, path)

          assert html =~ ~s(id="language-switcher-dropdown")

          assert {:error, {:redirect, %{to: to}}} =
                   render_click(view, "change_locale", %{"locale" => "de"})

          assert to ==
                   "/themes/#{unquote(slug)}/payment-processing/#{meeting.id}" <>
                     "?locale=de&session_id=cs_TEST"
        end
      else
        test "without a customisation the theme's own payment card writes no style block",
             %{conn: conn, meeting: meeting} do
          {:ok, _view, html} =
            live(
              conn,
              "/themes/#{unquote(slug)}/payment-processing/#{meeting.id}?session_id=cs_TEST"
            )

          refute html =~ ":root:root"
        end
      end
    end
  end

  describe "an unknown theme slug" do
    test "sends the processing page home", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: %{"error" => "Payment not found."}}}} =
               live(conn, "/themes/no-such-theme/payment-processing/m-1?session_id=cs_TEST")
    end

    test "sends the cancelled page home", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} =
               live(conn, "/themes/no-such-theme/payment-cancelled/m-1")
    end

    test "redirects on the dead render, before anything is drawn", %{conn: conn} do
      conn = get(conn, "/themes/no-such-theme/payment-cancelled/m-1")
      assert redirected_to(conn) == "/"
    end
  end

  defp assert_primary(html, primary) do
    [style] = Regex.run(~r{<style[^>]*>.*?</style>}s, html)
    assert style =~ "--theme-primary: #{primary};"
  end

  defp route_module(path) do
    info = Phoenix.Router.route_info(TymeslotWeb.Router, "GET", path, "localhost")
    elem(info.phoenix_live_view, 0)
  end

  defp assert_theme_stylesheet(html, slug) do
    assert html =~ ~s(href="/assets/scheduling-theme-#{slug}.css")
    assert html =~ "#{slug}-theme"

    for {_id, other} <- @slugs, other != slug do
      refute html =~ "scheduling-theme-#{other}.css",
             "the #{slug} payment page loads the #{other} stylesheet"
    end
  end

  # The root layout's class already names the theme, so only the shell's own
  # test id shows which theme drew the page body.
  defp assert_theme_shell(html, slug, page) do
    assert html =~ ~s(data-testid="#{slug}-payment-#{page}")

    for {_id, other} <- @slugs, other != slug do
      refute html =~ ~s(data-testid="#{other}-payment-#{page}"),
             "the #{slug} payment page draws the #{other} shell"
    end
  end
end
