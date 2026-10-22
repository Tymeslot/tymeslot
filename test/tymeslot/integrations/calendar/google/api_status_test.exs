defmodule Tymeslot.Integrations.Calendar.Google.ApiStatusTest do
  @moduledoc """
  Google states throttling and quota exhaustion in a 403 as well as a 429.
  Those clear once the window passes, so they must be retried as
  `:rate_limited`, never discarded as a `:refused` write.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.Google.ApiStatus

  defp forbidden(reason, message) do
    body =
      Jason.encode!(%{
        "error" => %{
          "code" => 403,
          "message" => message,
          "errors" => [%{"domain" => "usageLimits", "reason" => reason, "message" => message}]
        }
      })

    {:ok, %Req.Response{status: 403, body: body}}
  end

  for {reason, message} <- [
        {"quotaExceeded", "Calendar usage limits exceeded."},
        {"dailyLimitExceeded", "Daily Limit Exceeded"},
        {"userRateLimitExceeded", "User Rate Limit Exceeded"},
        {"rateLimitExceeded", "Rate Limit Exceeded"}
      ] do
    test "a 403 with reason #{reason} is :rate_limited" do
      assert {:error, :rate_limited, unquote(message)} =
               ApiStatus.classify(forbidden(unquote(reason), unquote(message)))
    end
  end

  test "a quota reason alone, whatever the message, is :rate_limited" do
    assert {:error, :rate_limited, _msg} = ApiStatus.classify(forbidden("quotaExceeded", "Nope."))
  end

  test "a 403 with an unrecognised reason stays :refused" do
    assert {:error, :refused, _msg} =
             ApiStatus.classify(
               forbidden("forbiddenForNonOrganizer", "Cannot change this event.")
             )
  end

  test "a 403 for insufficient scopes stays :unauthorized" do
    assert {:error, :unauthorized, _msg} =
             ApiStatus.classify(
               forbidden(
                 "insufficientPermissions",
                 "Request had insufficient authentication scopes."
               )
             )
  end
end
