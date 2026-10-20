defmodule Tymeslot.Integrations.Calendar.Outlook.GraphStatusTest do
  @moduledoc """
  The 403s Graph answers carry their meaning in `error.code`: throttling, a
  permission failure, or a refusal of the request itself, which is neither a
  network failure nor worth sending again.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.Outlook.GraphStatus

  defp forbidden(code, message) do
    body = Jason.encode!(%{"error" => %{"code" => code, "message" => message}})
    {:ok, %{status: 403, body: body, headers: %{}}}
  end

  test "a 403 with an unrecognised code is :refused" do
    assert {:error, :refused, "The calendar cannot be changed."} =
             GraphStatus.classify(
               forbidden("ErrorInvalidRequest", "The calendar cannot be changed.")
             )
  end

  test "a 403 with a throttling code stays :rate_limited" do
    assert {:error, :rate_limited, _msg} =
             GraphStatus.classify(
               forbidden("ApplicationThrottled", "Application has been throttled")
             )
  end

  test "a 403 with an access-denied code is :unauthorized" do
    assert {:error, :unauthorized, _msg} =
             GraphStatus.classify(forbidden("ErrorAccessDenied", "Access is denied."))
  end

  test "any other status is left to the shared envelope" do
    assert GraphStatus.classify({:ok, %{status: 412, body: "", headers: %{}}}) == :default
  end
end
