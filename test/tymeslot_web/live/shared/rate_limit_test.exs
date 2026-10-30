defmodule TymeslotWeb.Live.Shared.RateLimitTest do
  use ExUnit.Case, async: true

  @moduletag :security

  alias Phoenix.Flash
  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Live.Shared.RateLimit

  defp socket, do: %Socket{assigns: %{__changed__: %{}, flash: %{}}}

  defp action do
    fn ->
      send(self(), :action_ran)
      {:noreply, :ran}
    end
  end

  describe "with_rate_limit/4 when the check passes" do
    test "returns the action's result" do
      assert RateLimit.with_rate_limit(:ok, socket(), action()) == {:noreply, :ran}
      assert_received :action_ran
    end
  end

  describe "with_rate_limit/4 when rate limited" do
    test "skips the action and forwards the limiter's message to the parent" do
      socket = socket()

      assert {:noreply, ^socket} =
               RateLimit.with_rate_limit({:error, :rate_limited, "Slow down"}, socket, action())

      refute_received :action_ran
      assert_received {:flash, {:error, "Slow down"}}
    end

    test "uses the action's own message when one is given" do
      RateLimit.with_rate_limit({:error, :rate_limited, "Slow down"}, socket(), action(),
        message: "Too many updates"
      )

      assert_received {:flash, {:error, "Too many updates"}}
    end

    test "writes the flash on the socket for a LiveView that renders its own" do
      assert {:noreply, socket} =
               RateLimit.with_rate_limit({:error, :rate_limited, "Slow down"}, socket(), action(),
                 flash: :socket
               )

      assert Flash.get(socket.assigns.flash, :error) == "Slow down"
      refute_received {:flash, _}
    end

    test "returns the bare socket for a helper a handler pipes through" do
      socket = socket()

      assert RateLimit.with_rate_limit({:error, :rate_limited, "Slow down"}, socket, action(),
               reply: :socket
             ) == socket
    end
  end

  describe "with_rate_limit/4 when the key is invalid" do
    test "skips the action without a flash" do
      for refusal <- [{:error, :invalid_user_id}, {:error, :invalid_id}] do
        assert {:noreply, _socket} = RateLimit.with_rate_limit(refusal, socket(), action())
      end

      refute_received :action_ran
      refute_received {:flash, _}
    end
  end
end
