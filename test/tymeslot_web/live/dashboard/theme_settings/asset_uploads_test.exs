defmodule TymeslotWeb.Dashboard.ThemeSettings.AssetUploadsTest do
  use ExUnit.Case, async: false
  @moduletag :utils
  @moduletag :themes

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Media.UploadConstraints
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.ThemeSettings.AssetUploads
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomizationComponent

  @user_id 4_242
  @bucket "theme_upload:#{@user_id}"
  @limit 5
  @window_ms 600_000

  setup do
    RateLimiter.clear_all()
    :ok
  end

  defp socket_with(entries) do
    %Socket{
      assigns: %{
        __changed__: %{},
        id: "theme-customization",
        theme_id: "1",
        profile: %{id: 1, user_id: @user_id},
        uploads: %{background_image_path: %{entries: entries}}
      }
    }
  end

  defp budget_remaining do
    Enum.reduce_while(1..(@limit + 1), 0, fn _i, spent ->
      case RateLimiter.check_rate_limit(@bucket, @limit, @window_ms) do
        :ok -> {:cont, spent + 1}
        {:error, :rate_limited} -> {:halt, spent}
      end
    end)
  end

  describe "consume/2 rate limiting" do
    test "does not charge the rate limit when no upload is waiting" do
      socket = socket_with([])

      for _i <- 1..20, do: AssetUploads.consume(socket, :background_image_path)

      assert budget_remaining() == @limit,
             "an idle change event must not spend the user's upload budget"
    end

    test "does not charge the rate limit while an upload is still in flight" do
      socket = socket_with([%{ref: "0", done?: false, cancelled?: false}])

      for _i <- 1..20, do: AssetUploads.consume(socket, :background_image_path)

      assert budget_remaining() == @limit
    end

    test "refuses a finished upload once the limit is spent" do
      for _i <- 1..@limit,
          do: assert(:ok = RateLimiter.check_rate_limit(@bucket, @limit, @window_ms))

      socket = socket_with([%{ref: "0", done?: true, cancelled?: false}])

      # Processing would call ThemeCustomizations.attach_asset/4 and touch the
      # database. Being refused before that is the whole point: the socket
      # comes back untouched and the user is told why.
      assert ^socket = AssetUploads.consume(socket, :background_image_path)
      assert_receive {:flash, {:error, message}}
      assert message =~ "Too many upload attempts"
    end
  end

  describe "configure/3" do
    test "declares no upload for a theme without asset fields" do
      socket = %Socket{assigns: %{__changed__: %{}}}

      assert AssetUploads.configure(socket, ThemeCustomizationComponent, []).assigns ==
               socket.assigns
    end

    test "declares one upload per asset field, named after it, with its kind's limit" do
      socket = %Socket{assigns: %{__changed__: %{}}}

      uploads =
        AssetUploads.configure(socket, ThemeCustomizationComponent,
          logo_path: :image,
          background_video_path: :video
        ).assigns.uploads

      assert uploads.logo_path.max_file_size == UploadConstraints.max_file_size(:image)

      assert uploads.background_video_path.max_file_size ==
               UploadConstraints.max_file_size(:video)

      assert uploads.logo_path.max_entries == 1
      refute Map.has_key?(uploads, :background_image_path)
    end
  end

  describe "consume/2 for a field the theme does not declare" do
    test "leaves the socket and the budget untouched" do
      # A finished entry sits in the undeclared field's config, so it is the
      # declared-field check that stops the consume, not `ready?/2`.
      entry = %{ref: "0", done?: true, cancelled?: false}
      socket = socket_with([entry])
      socket = put_in(socket.assigns.uploads[:logo_path], %{entries: [entry]})

      assert ^socket = AssetUploads.consume(socket, :logo_path)
      assert budget_remaining() == @limit
    end
  end
end
