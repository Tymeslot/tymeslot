defmodule Tymeslot.Infrastructure.ErrorTracking.FilterTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :unit

  alias Tymeslot.Infrastructure.ErrorTracking.Filter

  describe "sanitize/1" do
    test "redacts credentials nested at any depth under string keys" do
      context = %{
        "request" => %{"headers" => %{"authorization" => "Bearer x", "accept" => "text/html"}},
        "params" => %{"access_token" => "abc", "slug" => "30min"}
      }

      assert Filter.sanitize(context) == %{
               "request" => %{
                 "headers" => %{"authorization" => "[REDACTED]", "accept" => "text/html"}
               },
               "params" => %{"access_token" => "[REDACTED]", "slug" => "30min"}
             }
    end

    test "redacts credentials under atom keys and inside lists" do
      context = %{job: %{args: [%{password: "hunter2", user_id: 7}]}}

      assert Filter.sanitize(context) == %{job: %{args: [%{password: "[REDACTED]", user_id: 7}]}}
    end

    test "masks an email address embedded in a free-form string value" do
      context = %{"live_view" => %{"reason" => "no calendar for jane.doe@example.com today"}}

      assert Filter.sanitize(context) == %{
               "live_view" => %{"reason" => "no calendar for j***@example.com today"}
             }
    end

    test "masks email addresses inside lists of strings" do
      assert Filter.sanitize(%{"recipients" => ["ann@example.org", "ok"]}) ==
               %{"recipients" => ["a***@example.org", "ok"]}
    end

    test "leaves non-sensitive values untouched" do
      context = %{"request" => %{"path" => "/jane/30min", "method" => "GET"}, "user_id" => 42}

      assert Filter.sanitize(context) == context
    end
  end
end
