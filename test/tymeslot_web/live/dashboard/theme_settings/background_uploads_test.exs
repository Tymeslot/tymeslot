defmodule TymeslotWeb.Dashboard.ThemeSettings.BackgroundUploadsTest do
  use ExUnit.Case, async: false
  @moduletag :utils

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.ThemeSettings.BackgroundUploads

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
        uploads: %{background_image: %{entries: entries}}
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

      for _i <- 1..20, do: BackgroundUploads.consume(socket, :image)

      assert budget_remaining() == @limit,
             "an idle change event must not spend the user's upload budget"
    end

    test "does not charge the rate limit while an upload is still in flight" do
      socket = socket_with([%{done?: false, cancelled?: false}])

      for _i <- 1..20, do: BackgroundUploads.consume(socket, :image)

      assert budget_remaining() == @limit
    end

    test "refuses a finished upload once the limit is spent" do
      for _i <- 1..@limit,
          do: assert(:ok = RateLimiter.check_rate_limit(@bucket, @limit, @window_ms))

      socket = socket_with([%{done?: true, cancelled?: false}])

      # Processing would call ThemeUploadHelper and touch the database. Being
      # refused before that is the whole point: the socket comes back untouched
      # and the user is told why.
      assert ^socket = BackgroundUploads.consume(socket, :image)
      assert_receive {:flash, {:error, message}}
      assert message =~ "Too many upload attempts"
    end
  end
end
