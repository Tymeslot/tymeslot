defmodule Tymeslot.Infrastructure.MetricsTest do
  use ExUnit.Case, async: false

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.Metrics
  alias Tymeslot.Test.LogCapture

  setup do
    # Detach any handlers from previous test runs to avoid :already_exists errors
    test_handler = "metrics-test-handler-#{System.unique_integer([:positive])}"
    %{handler_id: test_handler}
  end

  describe "emit_calendar_operation/3" do
    test "emits telemetry event receivable by test handler", %{handler_id: handler_id} do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        handler_id,
        [:tymeslot, :calendar, :list_events],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, ref, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Metrics.emit_calendar_operation(:list_events, %{provider: :google}, %{duration: 100})

      assert_receive {:telemetry, ^ref, [:tymeslot, :calendar, :list_events], %{duration: 100},
                      %{provider: :google}}
    end
  end

  describe "time_operation/3" do
    test "measures duration, emits success event, returns result", %{handler_id: handler_id} do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        handler_id,
        [:tymeslot, :calendar, :sync],
        fn _event, measurements, metadata, _config ->
          send(parent, {:telemetry, ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      result = Metrics.time_operation(:sync, %{provider: :caldav}, fn -> {:ok, :synced} end)

      assert result == {:ok, :synced}

      assert_receive {:telemetry, ^ref, measurements, metadata}
      assert is_number(measurements.duration)
      assert measurements.duration >= 0
      assert metadata.status == :success
      assert metadata.provider == :caldav
    end

    test "an {:error, _} return is recorded as a failure, not a success", %{
      handler_id: handler_id
    } do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        handler_id,
        [:tymeslot, :calendar, :update_event],
        fn _event, measurements, metadata, _config ->
          send(parent, {:telemetry, ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      result =
        Metrics.time_operation(:update_event, %{}, fn -> {:error, "Unexpected status: 409"} end)

      assert result == {:error, "Unexpected status: 409"}

      assert_receive {:telemetry, ^ref, _measurements, metadata}
      assert metadata.status == :error
      assert metadata.error =~ "409"
    end

    test "on exception, emits error event and reraises", %{handler_id: handler_id} do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        handler_id,
        [:tymeslot, :calendar, :failing_op],
        fn _event, measurements, metadata, _config ->
          send(parent, {:telemetry, ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert_raise RuntimeError, "test error", fn ->
        Metrics.time_operation(:failing_op, %{}, fn -> raise "test error" end)
      end

      assert_receive {:telemetry, ^ref, measurements, metadata}
      assert metadata.status == :error
      assert metadata.error =~ ~s(%RuntimeError{message: "test error"})
      assert is_number(measurements.duration)
    end
  end

  describe "track_http_request/4" do
    test "emits [:tymeslot, :http, :request] with correct data", %{handler_id: handler_id} do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        handler_id,
        [:tymeslot, :http, :request],
        fn _event, measurements, metadata, _config ->
          send(parent, {:telemetry, ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Metrics.track_http_request("GET", "https://api.example.com/events", 200, 150.5)

      assert_receive {:telemetry, ^ref, %{duration: 150.5},
                      %{method: "GET", status_code: 200, url: url}}

      assert url =~ "api.example.com"
    end
  end

  describe "track_circuit_breaker_state/3" do
    test "emits state change event", %{handler_id: handler_id} do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        handler_id,
        [:tymeslot, :circuit_breaker, :state_change],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:telemetry, ref, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Metrics.track_circuit_breaker_state(:my_breaker, :closed, :open)

      assert_receive {:telemetry, ^ref,
                      %{breaker: :my_breaker, old_state: :closed, new_state: :open}}
    end
  end

  describe "track_pool_usage/2" do
    test "emits pool usage metrics", %{handler_id: handler_id} do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        handler_id,
        [:tymeslot, :connection_pool, :usage],
        fn _event, measurements, metadata, _config ->
          send(parent, {:telemetry, ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Metrics.track_pool_usage(:db_pool, in_use_count: 5, free_count: 3, queue_count: 0)

      assert_receive {:telemetry, ^ref, %{in_use: 5, free: 3, queue: 0}, %{pool: :db_pool}}
    end
  end

  describe "track_parsing_performance/4" do
    test "emits parser metrics with events_per_second calculation", %{handler_id: handler_id} do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        handler_id,
        [:tymeslot, :parser, :performance],
        fn _event, measurements, metadata, _config ->
          send(parent, {:telemetry, ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Metrics.track_parsing_performance(:ical, 1024, 500.0, 100)

      assert_receive {:telemetry, ^ref, measurements, %{parser: :ical}}
      assert measurements.duration == 500.0
      assert measurements.size == 1024
      assert measurements.event_count == 100
      assert measurements.events_per_second == 200.0
    end
  end

  describe "setup_handlers/0" do
    test "attaches all expected handlers" do
      # Detach any existing handlers first to avoid conflicts
      expected_events = [
        [:tymeslot, :calendar, :list_events],
        [:tymeslot, :calendar, :create_event],
        [:tymeslot, :calendar, :update_event],
        [:tymeslot, :calendar, :delete_event],
        [:tymeslot, :http, :request],
        [:tymeslot, :circuit_breaker, :state_change],
        [:tymeslot, :connection_pool, :usage],
        [:tymeslot, :parser, :performance]
      ]

      Enum.each(expected_events, fn event ->
        try do
          :telemetry.detach("#{inspect(event)}-handler")
        rescue
          _error -> :ok
        end
      end)

      assert :ok = Metrics.setup_handlers()

      # :telemetry.execute/3 succeeds even with zero handlers attached, so the
      # only meaningful assertion is that each event genuinely carries one.
      Enum.each(expected_events, fn event ->
        assert [%{id: handler_id}] = :telemetry.list_handlers(event)
        assert handler_id == "#{inspect(event)}-handler"
      end)

      # Clean up
      Enum.each(expected_events, fn event ->
        try do
          :telemetry.detach("#{inspect(event)}-handler")
        rescue
          _error -> :ok
        end
      end)
    end
  end

  describe "handle_http_event/4" do
    test "does not log for successful fast requests" do
      LogCapture.attach()

      Metrics.handle_http_event(
        [:tymeslot, :http, :request],
        %{duration: 100},
        %{method: "GET", url: "https://example.com", status_code: 200},
        nil
      )

      refute_receive {:captured_log, _}, 100
    end

    test "logs host and redacted path but drops the URL query string on errors" do
      LogCapture.attach()

      Metrics.handle_http_event(
        [:tymeslot, :http, :request],
        %{duration: 100},
        %{
          method: "GET",
          url:
            "https://www.googleapis.com/calendar/v3/calendars/secret@import.calendar.google.com/events?maxResults=2500&timeMin=2025-06-07T18:15:04Z",
          status_code: 404
        },
        nil
      )

      assert_receive {:captured_log, %{meta: %{status_code: 404} = meta}}
      assert meta.host == "www.googleapis.com"
      assert meta.path == "/calendar/v3/calendars/:id/events"
      refute Map.has_key?(meta, :url)
      refute meta.path =~ "maxResults"
      refute meta.path =~ "@"
    end

    test "redacts a Google ical feed secret on a 401 response" do
      LogCapture.attach()

      Metrics.handle_http_event(
        [:tymeslot, :http, :request],
        %{duration: 100},
        %{
          method: "GET",
          url:
            "https://calendar.google.com/calendar/ical/user%40gmail.com/private-abc123def456/basic.ics",
          status_code: 401
        },
        nil
      )

      assert_receive {:captured_log, %{meta: %{status_code: 401} = meta}}
      refute meta.path =~ "private-abc123def456"
      refute meta.path =~ "%40"
      refute meta.path =~ "user@gmail.com"
    end

    test "redacts a Telegram bot token carried in the request path" do
      LogCapture.attach()

      Metrics.handle_http_event(
        [:tymeslot, :http, :request],
        %{duration: 100},
        %{
          method: "POST",
          url:
            "https://api.telegram.org/bot123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw/sendMessage",
          status_code: 403
        },
        nil
      )

      assert_receive {:captured_log, %{meta: %{status_code: 403} = meta}}
      assert meta.path == "/:id/sendMessage"
      refute meta.path =~ "AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"
    end

    test "redacts a Telegram bot token on a request slow enough to log" do
      LogCapture.attach()

      Metrics.handle_http_event(
        [:tymeslot, :http, :request],
        %{duration: 10_001},
        %{
          method: "POST",
          url:
            "https://api.telegram.org/bot987654321:BBGxrUdwDI2wHXKygTfpgTBt1L6QBMEtbx/setWebhook",
          status_code: 0
        },
        nil
      )

      assert_receive {:captured_log, %{meta: meta}}
      refute meta.path =~ "BBGxrUdwDI2wHXKygTfpgTBt1L6QBMEtbx"
    end

    test "leaves an ordinary API path unredacted on a slow response" do
      LogCapture.attach()

      Metrics.handle_http_event(
        [:tymeslot, :http, :request],
        %{duration: 5001},
        %{method: "GET", url: "https://api.example.com/api/v1/meetings/123", status_code: 200},
        nil
      )

      assert_receive {:captured_log, %{meta: meta}}
      assert meta.path == "/api/v1/meetings/123"
    end
  end

  describe "handle_pool_event/4" do
    test "does not log when pool is not under stress" do
      LogCapture.attach()

      Metrics.handle_pool_event(
        [:tymeslot, :connection_pool, :usage],
        %{in_use: 3, free: 5, queue: 0},
        %{pool: :test},
        nil
      )

      refute_receive {:captured_log, _}, 100
    end
  end

  describe "handle_parser_event/4" do
    test "does not log for fast operations" do
      LogCapture.attach()

      Metrics.handle_parser_event(
        [:tymeslot, :parser, :performance],
        %{duration: 50, size: 100, event_count: 10},
        %{parser: :ical},
        nil
      )

      refute_receive {:captured_log, _}, 100
    end
  end

  describe "sanitize_url (via track_http_request)" do
    test "removes userinfo from URLs", %{handler_id: handler_id} do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        handler_id,
        [:tymeslot, :http, :request],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:telemetry, ref, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Metrics.track_http_request("GET", "https://user:pass@api.example.com/path", 200, 100)

      assert_receive {:telemetry, ^ref, %{url: url}}
      refute url =~ "user:pass"
      assert url =~ "api.example.com"
    end
  end
end
