defmodule Tymeslot.Infrastructure.ErrorTracking.FilterTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :unit

  import ExUnit.CaptureLog

  alias Tymeslot.Infrastructure.ErrorTracking.Filter
  alias Tymeslot.Infrastructure.Logging.MetadataRedactor

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

    test "masks an email address inside a tuple" do
      assert Filter.sanitize(%{"result" => {:error, "no invite for bob@example.com"}}) ==
               %{"result" => {:error, "no invite for b***@example.com"}}
    end

    test "stops at the redactor's depth bound instead of walking without limit" do
      nest = fn levels, inner -> Enum.reduce(1..levels, inner, &%{"n#{&1}" => &2}) end
      max = MetadataRedactor.max_depth()

      assert Filter.sanitize(nest.(max - 1, "ann@example.org")) ==
               nest.(max - 1, "a***@example.org")

      deepest = nest.(max * 50, "ann@example.org")
      assert Filter.sanitize(deepest) == deepest
    end

    test "leaves non-sensitive values untouched" do
      context = %{"request" => %{"path" => "/jane/30min", "method" => "GET"}, "user_id" => 42}

      assert Filter.sanitize(context) == context
    end
  end

  describe "sanitize_with/2 (the fail-closed guard sanitize/1 runs under)" do
    test "stores a placeholder instead of the raw context when redaction raises" do
      context = %{"password" => "hunter2", "note" => "ann@example.org"}

      log =
        capture_log(fn ->
          assert Filter.sanitize_with(context, fn _context -> raise "redaction bug" end) ==
                   %{"context_redaction_failed" => true}
        end)

      assert log =~ "context redaction failed"
      refute log =~ "hunter2"
      refute log =~ "ann@example.org"
    end
  end
end
