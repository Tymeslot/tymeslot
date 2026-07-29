defmodule Tymeslot.MailerTest do
  # async: false — pins the mailer adapter and swaps Swoosh's API client for
  # the duration of these tests.
  use ExUnit.Case, async: false
  @moduletag :mailer

  import Swoosh.Email

  alias Tymeslot.Mailer

  # A fake Swoosh.ApiClient that captures the outgoing request instead of
  # making a real HTTP call — this is the external boundary (`:swoosh, :api_client`
  # is disabled in `config/test.exs` precisely to make an accidental real
  # delivery blow up loudly), so mocking it here is legitimate.
  defmodule CapturingApiClient do
    @moduledoc false
    @behaviour Swoosh.ApiClient

    @impl Swoosh.ApiClient
    def post(_url, _headers, body, _email) do
      send(self(), {:mailer_test_posted_body, body})
      {:ok, 200, [], Jason.encode!(%{"MessageID" => "test-message-id"})}
    end
  end

  defp build_email do
    new()
    |> from({"Tymeslot", "hello@tymeslot.app"})
    |> to({"Test", "test@example.com"})
    |> subject("Subject")
    |> text_body("Body")
  end

  describe "deliver/2 tracking composition" do
    setup do
      original_mailer_config = Application.get_env(:tymeslot, Tymeslot.Mailer)
      original_api_client = Application.get_env(:swoosh, :api_client)

      Application.put_env(:tymeslot, Tymeslot.Mailer,
        adapter: Swoosh.Adapters.Postmark,
        api_key: "test-key"
      )

      Application.put_env(:swoosh, :api_client, CapturingApiClient)

      on_exit(fn ->
        Application.put_env(:tymeslot, Tymeslot.Mailer, original_mailer_config)
        Application.put_env(:swoosh, :api_client, original_api_client)
      end)

      :ok
    end

    test "applies the configured adapter's tracking options for the email's tracking category" do
      email = Mailer.put_tracking(build_email(), :marketing)

      assert {:ok, _result} = Mailer.deliver(email)

      assert_receive {:mailer_test_posted_body, body}
      decoded = Jason.decode!(body)

      assert decoded["TrackOpens"] == true
      assert decoded["TrackLinks"] == "HtmlAndText"
      assert decoded["MessageStream"] == "broadcast"
    end

    test "an email without the private key carries no tracking options" do
      email = build_email()

      assert {:ok, _result} = Mailer.deliver(email)

      assert_receive {:mailer_test_posted_body, body}
      decoded = Jason.decode!(body)

      refute Map.has_key?(decoded, "TrackOpens")
      refute Map.has_key?(decoded, "TrackLinks")
      refute Map.has_key?(decoded, "MessageStream")
    end
  end

  describe "api_providers/0" do
    test "lists exactly the API-key-based providers, by name" do
      names = Mailer.api_providers() |> Enum.map(& &1.name) |> Enum.sort()

      assert names == ~w(ahasend mailgun postmark sendgrid)
    end
  end

  describe "put_tracking/2" do
    test "rejects an unknown tracking category" do
      # Built dynamically rather than as a literal so the compiler's type
      # checker can't prove this call invalid ahead of time — the point of
      # this test is the runtime guard on put_tracking/2, not a compile-time
      # warning.
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      bogus_category = String.to_atom("bogus")

      assert_raise FunctionClauseError, fn ->
        Mailer.put_tracking(build_email(), bogus_category)
      end
    end
  end
end
