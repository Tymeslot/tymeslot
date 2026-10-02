defmodule Tymeslot.Infrastructure.Logging.MetadataRedactorTest do
  use ExUnit.Case, async: false

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.Logging.MetadataRedactor

  # Most assertions exercise filter/2 directly: capture_log goes through the
  # default formatter, which only prints metadata keys whitelisted in its
  # `metadata:` list — so non-whitelisted keys (api_key, password, ...) are
  # invisible whether redacted or not. Testing the filter function directly
  # is what verifies the security guarantee.

  defp event(meta), do: %{level: :info, msg: {:string, "test"}, meta: meta}

  describe "redact/1" do
    test "redacts sensitive keys at any depth, under atom and string keys, inside lists and tuples" do
      term = %{
        "request" => %{"headers" => %{"authorization" => "Bearer x", "accept" => "*/*"}},
        job: [%{api_key: "sk-1", user_id: 7}],
        pair: {:ok, %{"password" => "pw"}}
      }

      assert MetadataRedactor.redact(term) == %{
               "request" => %{"headers" => %{"authorization" => "[REDACTED]", "accept" => "*/*"}},
               job: [%{api_key: "[REDACTED]", user_id: 7}],
               pair: {:ok, %{"password" => "[REDACTED]"}}
             }
    end

    test "stops at max_depth/0, leaving deeper terms as they are" do
      nest = fn levels, inner -> Enum.reduce(1..levels, inner, &%{"n#{&1}" => &2}) end
      max = MetadataRedactor.max_depth()

      assert MetadataRedactor.redact(nest.(max - 1, %{"password" => "pw"})) ==
               nest.(max - 1, %{"password" => "[REDACTED]"})

      deepest = nest.(max, %{"password" => "pw"})
      assert MetadataRedactor.redact(deepest) == deepest
    end
  end

  describe "filter/2" do
    test "redacts sensitive atom keys" do
      filtered =
        MetadataRedactor.filter(
          event(%{api_key: "sk-abc123", user_id: 42, password: "pw"}),
          []
        )

      assert filtered.meta.api_key == "[REDACTED]"
      assert filtered.meta.password == "[REDACTED]"
      assert filtered.meta.user_id == 42
    end

    test "matches sensitive substrings (refresh_token, set_cookie, x_authorization, ...)" do
      filtered =
        MetadataRedactor.filter(
          event(%{
            refresh_token: "rt-secret",
            set_cookie: "session=abc",
            x_authorization: "Bearer xyz",
            client_secret: "cs-secret",
            stripe_api_key: "sk-test",
            session_id: "session-token"
          }),
          []
        )

      assert filtered.meta.refresh_token == "[REDACTED]"
      assert filtered.meta.set_cookie == "[REDACTED]"
      assert filtered.meta.x_authorization == "[REDACTED]"
      assert filtered.meta.client_secret == "[REDACTED]"
      assert filtered.meta.stripe_api_key == "[REDACTED]"
      assert filtered.meta.session_id == "[REDACTED]"
    end

    test "matches case-insensitively and against string keys" do
      filtered =
        MetadataRedactor.filter(
          event(%{"API_KEY" => "leak", :Password => "leak2", :note => "kept"}),
          []
        )

      assert filtered.meta["API_KEY"] == "[REDACTED]"
      assert filtered.meta[:Password] == "[REDACTED]"
      assert filtered.meta[:note] == "kept"
    end

    test "redacts calendar identifiers but keeps the integration id" do
      filtered =
        MetadataRedactor.filter(
          event(%{
            calendar_id: "user@example.com",
            calendar_ids: ["a@example.com", "b@example.com"],
            calendar_path: "/calendars/user@example.com/work/",
            calendar_integration_id: 42
          }),
          []
        )

      assert filtered.meta.calendar_id == "[REDACTED]"
      assert filtered.meta.calendar_ids == "[REDACTED]"
      assert filtered.meta.calendar_path == "[REDACTED]"
      assert filtered.meta.calendar_integration_id == 42
    end

    test "redacts personal identifier keys but keeps pre-masked and non-address ones" do
      filtered =
        MetadataRedactor.filter(
          event(%{
            email: "alice@example.com",
            attendee_email: "bob@example.com",
            identifier: "carol@example.com",
            email_masked: "a***@example.com",
            identifier_masked: "c***@example.com",
            owner_email_masked: "d***@example.com",
            email_action: "reminder",
            provider_identifier: "evt_abc123"
          }),
          []
        )

      assert filtered.meta.email == "[REDACTED]"
      assert filtered.meta.attendee_email == "[REDACTED]"
      assert filtered.meta.identifier == "[REDACTED]"

      # `_masked` names a value the writer already masked, and the two keys
      # below carry no address at all — blanking either costs diagnostics for
      # no privacy gain.
      assert filtered.meta.email_masked == "a***@example.com"
      assert filtered.meta.identifier_masked == "c***@example.com"
      assert filtered.meta.owner_email_masked == "d***@example.com"
      assert filtered.meta.email_action == "reminder"
      assert filtered.meta.provider_identifier == "evt_abc123"
    end

    test "redacts an email's recipients, subject and title but keeps keys that only end alike" do
      recipient = [{"Jane Invitee", "jane@example.com"}]

      filtered =
        MetadataRedactor.filter(
          event(%{
            to: recipient,
            cc: recipient,
            bcc: recipient,
            reply_to: {"Jane Invitee", "jane@example.com"},
            recipient: "jane@example.com",
            recipients: ["jane@example.com"],
            admin_recipient: "ops@example.com",
            subject: "Meeting Cancelled with Jane Invitee",
            title: "Intro call with Jane Invitee",
            redirect_to: "/dashboard",
            recipient_domains: ["example.com"],
            meeting_id: 7
          }),
          []
        )

      for key <- [:to, :cc, :bcc, :reply_to, :recipient, :recipients, :admin_recipient] do
        assert filtered.meta[key] == "[REDACTED]", "expected #{key} to be redacted"
      end

      assert filtered.meta.subject == "[REDACTED]"
      assert filtered.meta.title == "[REDACTED]"

      # `to` is matched whole and `recipient` only as a suffix, so a path and
      # the domains a delivery went to stay readable.
      assert filtered.meta.redirect_to == "/dashboard"
      assert filtered.meta.recipient_domains == ["example.com"]
      assert filtered.meta.meeting_id == 7
    end

    test "redacts the recipients of a Swoosh email nested in a report" do
      email = %Swoosh.Email{
        to: [{"Jane Invitee", "jane@example.com"}],
        subject: "Meeting Cancelled with Jane Invitee"
      }

      redacted = MetadataRedactor.redact(%{args: [email]})
      rendered = inspect(redacted)

      refute rendered =~ "jane@example.com"
      refute rendered =~ "Jane Invitee"
    end

    test "truncates client IP addresses to their network instead of blanking them" do
      filtered =
        MetadataRedactor.filter(
          event(%{
            "x-forwarded-for" => "203.0.113.77, 10.0.0.1",
            ip: "203.0.113.77",
            ip_address: "2001:db8:85a3:8d3:1319:8a2e:370:7348",
            client_ip: {198, 51, 100, 9},
            remote_ip: ~c"192.0.2.5",
            origin_ip: "198.51.100.200"
          }),
          []
        )

      assert filtered.meta.ip == "203.0.113.0/24"
      assert filtered.meta.ip_address == "2001:db8:85a3::/48"
      assert filtered.meta.client_ip == "198.51.100.0/24"
      assert filtered.meta.remote_ip == "192.0.2.0/24"
      assert filtered.meta["x-forwarded-for"] == "203.0.113.0/24, 10.0.0.0/24"

      # The server's own egress address, not a visitor's.
      assert filtered.meta.origin_ip == "198.51.100.200"
    end

    test "keeps absent or unknown client IPs and blanks one it cannot parse" do
      filtered =
        MetadataRedactor.filter(
          event(%{ip: nil, client_ip: "unknown", ip_address: "\"203.0.113.77\""}),
          []
        )

      assert filtered.meta.ip == nil
      assert filtered.meta.client_ip == "unknown"
      assert filtered.meta.ip_address == "[REDACTED]"
    end

    test "truncates a client IP nested in a report and in keyword lists" do
      redacted =
        MetadataRedactor.redact(%{
          conn: %{remote_ip: {203, 0, 113, 77}},
          opts: [ip: "203.0.113.77"]
        })

      assert redacted == %{conn: %{remote_ip: "203.0.113.0/24"}, opts: [ip: "203.0.113.0/24"]}
    end

    test "redacts the meeting uid, a bearer capability, but not a bare calendar event uid" do
      filtered =
        MetadataRedactor.filter(
          event(%{
            meeting_uid: "0b7e1f3a-4c1d-4a8e-9f3b-2d6c8e1a5b7c",
            uid: "evt-123@google.com"
          }),
          []
        )

      assert filtered.meta.meeting_uid == "[REDACTED]"
      assert filtered.meta.uid == "evt-123@google.com"
    end

    test "leaves non-sensitive metadata untouched" do
      filtered =
        MetadataRedactor.filter(
          event(%{
            user_id: 1,
            correlation_id: "abc",
            duration_ms: 12,
            event: :login_success
          }),
          []
        )

      assert filtered.meta == %{
               user_id: 1,
               correlation_id: "abc",
               duration_ms: 12,
               event: :login_success
             }
    end

    test "ignores events without a meta map" do
      ev = %{level: :info, msg: {:string, "no meta"}}
      assert MetadataRedactor.filter(ev, []) == ev
    end

    test "leaves non-atom non-string keys alone" do
      filtered = MetadataRedactor.filter(event(%{{:tagged, "k"} => "v"}), [])
      assert filtered.meta == %{{:tagged, "k"} => "v"}
    end
  end

  describe "filter/2 over nested metadata values" do
    test "redacts a sensitive key inside a map value" do
      filtered = MetadataRedactor.filter(event(%{error: %{"access_token" => "abc"}}), [])

      assert filtered.meta.error == %{"access_token" => "[REDACTED]"}
    end

    test "redacts a token nested three levels down, keeping its siblings" do
      meta = %{response: %{body: %{data: %{refresh_token: "rt-1", expires_in: 3600}}}}

      filtered = MetadataRedactor.filter(event(meta), [])

      assert filtered.meta.response.body.data == %{
               refresh_token: "[REDACTED]",
               expires_in: 3600
             }
    end

    test "redacts inside keyword lists, lists and structs" do
      meta = %{
        opts: [api_key: "sk-1", timeout: 5_000],
        attempts: [%{password: "pw", n: 1}],
        exception: %RuntimeError{message: "boom"},
        request: %URI{host: "example.com", userinfo: "user", query: "a=1"}
      }

      filtered = MetadataRedactor.filter(event(meta), [])

      assert filtered.meta.opts == [api_key: "[REDACTED]", timeout: 5_000]
      assert filtered.meta.attempts == [%{password: "[REDACTED]", n: 1}]
      assert filtered.meta.exception == %RuntimeError{message: "boom"}
      assert %URI{host: "example.com"} = filtered.meta.request
    end

    test "walks five levels into a metadata value and no further" do
      nest = fn levels -> Enum.reduce(1..levels, %{token: "t"}, &%{"n#{&1}" => &2}) end

      # The metadata key is level zero; the token's own key sits at level five.
      assert MetadataRedactor.filter(event(%{ctx: nest.(4)}), []).meta.ctx ==
               Enum.reduce(1..4, %{token: "[REDACTED]"}, &%{"n#{&1}" => &2})

      deep = nest.(5)
      assert MetadataRedactor.filter(event(%{ctx: deep}), []).meta.ctx == deep
    end

    test "passes odd terms through unchanged rather than raising inside the logger" do
      pid = self()
      ref = make_ref()
      fun = fn -> :ok end
      large = :binary.copy("x", 1_000_000)
      large_key_map = %{large => "value"}

      meta = %{
        improper: ["abc" | "def"],
        nested_improper: [%{password: "pw"} | :tail],
        tuple: {:ok, 1, 2},
        pid: pid,
        ref: ref,
        fun: fun,
        large: large,
        large_key_map: large_key_map,
        charlist: ~c"plain text",
        empty: [],
        nil_value: nil
      }

      filtered = MetadataRedactor.filter(event(meta), []).meta

      assert filtered.improper == ["abc" | "def"]
      assert filtered.nested_improper == [%{password: "[REDACTED]"} | :tail]
      assert filtered.tuple == {:ok, 1, 2}
      assert filtered.pid == pid
      assert filtered.ref == ref
      assert filtered.fun == fun
      assert filtered.large == large
      assert filtered.large_key_map == large_key_map
      assert filtered.charlist == ~c"plain text"
      assert filtered.empty == []
      assert filtered.nil_value == nil
    end
  end

  describe "filter/2 over message reports" do
    test "redacts a credential nested inside an OTP report's arguments" do
      # The shape an OTP task-termination report actually has: the crashed
      # function's arguments verbatim, with a calendar client — and its
      # decrypted CalDAV password — sitting inside them.
      report = %{
        label: {Task.Supervisor, :terminating},
        report: %{
          args: [:some_fun, [%{client: %{username: "LR07587", password: "s3cret"}}]],
          reason: {%RuntimeError{message: "boom"}, []}
        }
      }

      assert %{msg: {:report, filtered}} =
               MetadataRedactor.filter(
                 %{level: :error, msg: {:report, report}, meta: %{}},
                 []
               )

      assert [_fun, [%{client: client}]] = filtered.report.args
      assert client.password == "[REDACTED]"

      # The rest of the report has to survive, or the redaction has cost us
      # the diagnostic the report existed for.
      assert client.username == "LR07587"
      assert {%RuntimeError{message: "boom"}, []} = filtered.report.reason
      assert filtered.label == {Task.Supervisor, :terminating}
    end

    test "redacts sensitive keys in a {format, args} message" do
      assert %{msg: {~c"~p", args}} =
               MetadataRedactor.filter(
                 %{
                   level: :error,
                   msg: {~c"~p", [%{api_key: "sk-abc123", user_id: 42}]},
                   meta: %{}
                 },
                 []
               )

      assert [%{api_key: "[REDACTED]", user_id: 42}] = args
    end

    test "leaves {:string, chardata} messages alone" do
      msg = {:string, ["password: ", "s3cret"]}

      assert %{msg: ^msg} =
               MetadataRedactor.filter(%{level: :error, msg: msg, meta: %{}}, [])
    end

    test "preserves an improper list rather than raising inside the logger" do
      chardata = ["abc" | "def"]

      assert %{msg: {:report, filtered}} =
               MetadataRedactor.filter(
                 %{level: :error, msg: {:report, %{note: chardata, token: "t"}}, meta: %{}},
                 []
               )

      assert filtered.note == chardata
      assert filtered.token == "[REDACTED]"
    end

    test "keeps a struct in the report a struct" do
      assert %{msg: {:report, filtered}} =
               MetadataRedactor.filter(
                 %{
                   level: :error,
                   msg: {:report, %{error: %ArgumentError{message: "bad"}}},
                   meta: %{}
                 },
                 []
               )

      assert %ArgumentError{message: "bad"} = filtered.error
    end

    test "redacts within the depth cap and stops descending past it" do
      nest = fn levels ->
        Enum.reduce(1..levels, %{password: "s3cret"}, fn _level, acc -> %{nested: acc} end)
      end

      innermost = fn term ->
        Enum.reduce_while(1..100, term, fn _step, acc ->
          case acc do
            %{nested: deeper} -> {:cont, deeper}
            %{password: password} -> {:halt, password}
          end
        end)
      end

      assert %{msg: {:report, shallow}} =
               MetadataRedactor.filter(%{level: :error, msg: {:report, nest.(5)}, meta: %{}}, [])

      assert innermost.(shallow) == "[REDACTED]"

      assert %{msg: {:report, deep}} =
               MetadataRedactor.filter(%{level: :error, msg: {:report, nest.(40)}, meta: %{}}, [])

      # Past the cap the term is handed on untouched rather than walked
      # forever. Anything nested that deeply is not a shape credentials
      # arrive in; bounding the walk keeps logging cheap.
      assert innermost.(deep) == "s3cret"
    end
  end

  defp primary_filter(id),
    do: :logger.get_primary_config() |> Map.fetch!(:filters) |> Keyword.get(id)

  defp restore_primary_filter(id, previous) do
    _removed = :logger.remove_primary_filter(id)
    if previous, do: :ok = :logger.add_primary_filter(id, previous)
    :ok
  end

  describe "attach/0" do
    test "is idempotent and survives repeated calls" do
      # The application installs this filter at boot and other tests rely on
      # it, so put back exactly what was there rather than removing it.
      previous = primary_filter(:tymeslot_metadata_redactor)
      on_exit(fn -> restore_primary_filter(:tymeslot_metadata_redactor, previous) end)

      assert :ok = MetadataRedactor.attach()
      assert :ok = MetadataRedactor.attach()

      filter_ids = :logger.get_primary_config() |> Map.fetch!(:filters) |> Keyword.keys()
      assert :tymeslot_metadata_redactor in filter_ids
    end
  end

  describe "through the installed logger filter" do
    alias Tymeslot.Bookings.Policy
    alias Tymeslot.Test.LogCapture

    # A real call site: blocking the reschedule of a meeting that has started
    # logs its uid. The primary filter installed at boot must blank it before
    # any handler sees it.
    test "a logged meeting uid reaches handlers redacted" do
      now = DateTime.utc_now()

      meeting = %{
        uid: "0b7e1f3a-4c1d-4a8e-9f3b-2d6c8e1a5b7c",
        status: "confirmed",
        start_time: DateTime.add(now, -600),
        end_time: DateTime.add(now, 600)
      }

      LogCapture.with_capture([logger_level: :info], fn ->
        assert {:error, _reason} = Policy.can_reschedule_meeting?(meeting)

        %{meta: meta} = LogCapture.await_log("Blocked reschedule")
        assert meta.meeting_uid == "[REDACTED]"
      end)
    end
  end
end
