defmodule TymeslotWeb.Themes.Shared.PathHandlersPreviewEmbedTest do
  use TymeslotWeb.ConnCase, async: true
  @moduletag :utils
  @moduletag :themes

  alias TymeslotWeb.Live.Scheduling.PreviewMode
  alias TymeslotWeb.Themes.Core.Context
  alias TymeslotWeb.Themes.Shared.PathHandlers

  describe "build_path_with_locale/2 inside an owner preview" do
    # A locale switch is a full external redirect, so the LiveView that comes
    # back has no assigns and knows only what the URL carries. The preview
    # session therefore has to be rebuilt in the query string as a set: the
    # claim, the token, and the previewed theme. Dropping any one of them
    # changes what a booking does.

    test "carries the claim, the token and the previewed theme" do
      socket = preview_socket(theme_preview: true, preview_token: "signed-token")

      path = PathHandlers.build_path_with_locale(socket, "de")
      params = query_params(path)

      assert params["locale"] == "de"
      assert params["preview"] == "true"
      assert params["preview_token"] == "signed-token"
      assert params["theme"] == "2"
    end

    test "keeps simulating rather than booking for real after the switch" do
      # The load-bearing one. Without `preview` and `preview_token` in the
      # redirect, the owner lands on a page that still looks like their preview
      # but persists a real meeting they never see, which is precisely what the
      # fail-closed branch exists to prevent.
      socket = preview_socket(theme_preview: true, preview_token: "signed-token")

      params = socket |> PathHandlers.build_path_with_locale("de") |> query_params()

      assert params["preview"] == "true"
      assert params["preview_token"] == "signed-token"
    end

    test "carries the claim even once the token has gone, so the booking still fails closed" do
      # An expired token must not silently downgrade the page to a real
      # booking. The claim survives on its own and the submission is blocked.
      socket = preview_socket(theme_preview: true, preview_token: nil)

      params = socket |> PathHandlers.build_path_with_locale("de") |> query_params()

      assert params["preview"] == "true"
      refute Map.has_key?(params, "preview_token")
    end

    test "a verified owner counts as a preview even when the URL claim was dropped" do
      # `:owner_preview` is sticky across internal navigation while
      # `:theme_preview` is re-read from the params, so mid-flow only the
      # former may be set. Either is enough to mean "this is a preview".
      socket = preview_socket(theme_preview: false, preview_token: "signed-token")
      socket = put_in(socket.assigns[:owner_preview], true)

      params = socket |> PathHandlers.build_path_with_locale("de") |> query_params()

      assert params["preview"] == "true"
      assert params["preview_token"] == "signed-token"
    end
  end

  describe "build_path_with_locale/2 inside an embed" do
    # The redirect is a full page load inside the iframe. Unless it is rebuilt
    # as an embed URL, the page that comes back has no embed token (a paid
    # booking tries to open Stripe Checkout inside the frame) and the embed's
    # layout, accent colour and theme fall back to the organiser's defaults.

    test "carries the embed flag, parent origin, theme, layout and colour" do
      params =
        embed_socket(embed_layout: :column, theme_overrides: %{primary_color: "#e11d48"})
        |> PathHandlers.build_path_with_locale("de")
        |> query_params()

      assert params == %{
               "locale" => "de",
               "embed" => "1",
               "parent-origin" => "https://embedder.test",
               "theme" => "2",
               "layout" => "column",
               "primary-color" => "#e11d48"
             }
    end

    test "leaves out a layout and a colour the page did not accept" do
      # The theme context drops an invalid `primary-color` and any layout but
      # `column`; the redirect reads the context, so nothing invalid is echoed.
      params =
        embed_socket(embed_layout: :default, theme_overrides: %{})
        |> PathHandlers.build_path_with_locale("de")
        |> query_params()

      assert params == %{
               "locale" => "de",
               "embed" => "1",
               "parent-origin" => "https://embedder.test",
               "theme" => "2"
             }
    end

    test "an invalid colour on the embed URL is not carried into the redirect" do
      context = Context.from_params(%{"theme" => "2", "primary-color" => "red;}"})

      params =
        embed_socket([])
        |> Map.update!(:assigns, &Map.merge(&1, Context.to_assigns(context)))
        |> PathHandlers.build_path_with_locale("de")
        |> query_params()

      refute Map.has_key?(params, "primary-color")
      assert params["embed"] == "1"
      assert params["theme"] == "2"
    end

    test "does not turn an embedded visitor into a previewer" do
      params =
        embed_socket(theme_preview: false, owner_preview: false)
        |> PathHandlers.build_path_with_locale("de")
        |> query_params()

      refute Map.has_key?(params, "preview")
      refute Map.has_key?(params, "preview_token")
      refute PreviewMode.claimed?(params)
    end

    test "a standalone page carries none of the embed parameters" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: "johndoe",
          live_action: :overview,
          theme_id: "2",
          embed_layout: :column,
          theme_overrides: %{primary_color: "#e11d48"},
          embed_parent_origin: "https://embedder.test"
        }
      }

      assert PathHandlers.build_path_with_locale(socket, "de") == "/johndoe?locale=de"
    end
  end

  defp preview_socket(opts) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        username_context: "johndoe",
        live_action: :overview,
        theme_id: "2",
        theme_preview: Keyword.fetch!(opts, :theme_preview),
        owner_preview: false,
        preview_token: Keyword.fetch!(opts, :preview_token)
      }
    }
  end

  defp embed_socket(overrides) do
    assigns =
      Map.merge(
        %{
          username_context: "johndoe",
          live_action: :overview,
          theme_id: "2",
          embedded: true,
          embed_parent_origin: "https://embedder.test",
          embed_layout: :default,
          theme_overrides: %{}
        },
        Map.new(overrides)
      )

    %Phoenix.LiveView.Socket{assigns: assigns}
  end

  defp query_params(path) do
    path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
  end
end
