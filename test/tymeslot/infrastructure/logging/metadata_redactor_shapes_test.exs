defmodule Tymeslot.Infrastructure.Logging.MetadataRedactorShapesTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.Logging.MetadataRedactor

  defmodule Options do
    @moduledoc false
    defstruct [:client_secret, :timeout]
  end

  defp event(meta), do: %{level: :info, msg: {:string, "test"}, meta: meta}

  defp meta_after_filter(meta), do: MetadataRedactor.filter(event(meta), []).meta

  describe "tuples outside a list or map" do
    test "keep the payload of an error tuple whose tag reads like a sensitive key" do
      meta =
        meta_after_filter(%{
          expired: {:token_expired, %{status: 401}},
          invalid: {:invalid_token, "signature mismatch"},
          mismatch: {:password_mismatch, :attempt_3}
        })

      assert meta.expired == {:token_expired, %{status: 401}}
      assert meta.invalid == {:invalid_token, "signature mismatch"}
      assert meta.mismatch == {:password_mismatch, :attempt_3}
    end

    test "walk the first element as well as the second" do
      meta = meta_after_filter(%{response: {%{"access_token" => "x", "scope" => "read"}, 200}})

      assert meta.response == {%{"access_token" => "[REDACTED]", "scope" => "read"}, 200}
    end

    test "redact a Req auth credential under any key" do
      meta =
        meta_after_filter(%{
          opts: [auth: {:bearer, "tok"}, retry: false],
          basic: {:basic, "user:pass"},
          digest: %{auth: {:digest, "user:pass"}}
        })

      assert meta.opts == [auth: {:bearer, "[REDACTED]"}, retry: false]
      assert meta.basic == {:basic, "[REDACTED]"}
      assert meta.digest == %{auth: {:digest, "[REDACTED]"}}
    end
  end

  describe "pairs inside a list" do
    test "apply key semantics to header lists and proplists" do
      meta =
        meta_after_filter(%{
          headers: [{"authorization", "Bearer x"}, {"accept", "*/*"}],
          proplist: [{:api_key, "sk-1"}, {:region, "eu"}]
        })

      assert meta.headers == [{"authorization", "[REDACTED]"}, {"accept", "*/*"}]
      assert meta.proplist == [{:api_key, "[REDACTED]"}, {:region, "eu"}]
    end

    test "walk a pair's key when it is itself a term" do
      meta = meta_after_filter(%{pairs: [{%{"password" => "pw"}, :ok}]})

      assert meta.pairs == [{%{"password" => "[REDACTED]"}, :ok}]
    end

    test "keep a changeset validation message under a sensitive field, but not a value" do
      meta =
        meta_after_filter(%{
          errors: [password: {"is too short", [count: 8, validation: :length]}],
          params: [password: "hunter2"],
          map_errors: %{password: {"can't be blank", [validation: :required]}}
        })

      assert meta.errors == [password: {"is too short", [count: 8, validation: :length]}]
      assert meta.params == [password: "[REDACTED]"]
      assert meta.map_errors == %{password: {"can't be blank", [validation: :required]}}
    end
  end

  describe "crash_reason" do
    test "walks the reason and hands the stacktrace on untouched" do
      {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)

      meta =
        meta_after_filter(%{
          crash_reason: {{:invalid_token, %{"refresh_token" => "rt"}}, stacktrace}
        })

      assert {{:invalid_token, %{"refresh_token" => "[REDACTED]"}}, ^stacktrace} =
               meta.crash_reason
    end
  end

  describe "structs with their own Inspect implementation" do
    test "a Req request with a redacted field is rendered by Req's own, redacting, inspection" do
      request = %Req.Request{options: %{auth: "Bearer option-secret", client_secret: "cs-secret"}}

      rendered = meta_after_filter(%{request: request}).request

      assert rendered =~ ~r/\A%Req\.Request\{/
      assert rendered =~ ~s(client_secret: "[REDACTED]")
      refute rendered =~ "option-secret"
      refute rendered =~ "cs-secret"
    end

    test "a Req request its own inspection cannot render once redacted is redacted whole" do
      request = %Req.Request{
        headers: %{"authorization" => ["Bearer header-secret"]},
        options: %{auth: "Bearer option-secret"}
      }

      assert meta_after_filter(%{request: request}).request == "#Req.Request<[REDACTED]>"
    end

    test "a struct with a custom Inspect but nothing sensitive stays the struct it was" do
      now = DateTime.utc_now()
      uri = URI.parse("https://example.com/path")

      meta = meta_after_filter(%{at: now, url: uri})

      assert meta.at == now
      assert meta.url == uri
    end

    test "a struct without a custom Inspect keeps its type with the field redacted" do
      meta = meta_after_filter(%{opts: %Options{client_secret: "cs", timeout: 5}})

      assert meta.opts == %Options{client_secret: "[REDACTED]", timeout: 5}
    end
  end

  describe "a redaction failure" do
    test "keeps only the safe metadata keys rather than the unredacted event" do
      event = %{
        level: :error,
        msg: {:report, %{password: "pw"}},
        meta: %{
          request_id: "req-1",
          correlation_id: "corr-1",
          user_id: 7,
          mfa: {__MODULE__, :test, 1},
          api_key: "sk-1",
          reason: "raw"
        }
      }

      filtered = MetadataRedactor.filter_with(event, fn _event -> raise "boom" end)

      assert filtered.meta == %{
               request_id: "req-1",
               correlation_id: "corr-1",
               user_id: 7,
               mfa: {__MODULE__, :test, 1},
               redaction_failed: true
             }

      assert {:string, message} = filtered.msg
      refute IO.iodata_to_binary(message) =~ "pw"
      assert filtered.level == :error
    end

    test "is contained when the redactor throws or exits" do
      event = event(%{user_id: 1, token: "t"})

      assert %{meta: %{user_id: 1, redaction_failed: true}} =
               MetadataRedactor.filter_with(event, fn _event -> throw(:oops) end)

      assert %{meta: %{user_id: 1, redaction_failed: true}} =
               MetadataRedactor.filter_with(event, fn _event -> exit(:oops) end)
    end
  end
end
