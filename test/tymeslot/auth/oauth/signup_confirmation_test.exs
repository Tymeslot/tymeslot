defmodule Tymeslot.Auth.OAuth.SignupConfirmationTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth

  alias Tymeslot.Auth.OAuth.SignupConfirmation
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.EmailWorker

  defp oauth_data(email),
    do: %{email: email, provider_uid: "uid-#{email}", name: "Ada", terms_accepted: true}

  defp links(email) do
    all_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_social_signup_confirmation", "email" => email}
    )
  end

  test "spends the requesting address's verification allowance" do
    ip = "198.51.100.140"
    assert :sent = SignupConfirmation.request(:github, oauth_data("a@example.com"), %{}, ip)

    remaining =
      Enum.count(1..10, fn _i -> RateLimiter.check_verification_ip_rate_limit(ip) == :ok end)

    assert remaining == 4
  end

  test "reports the address limit, and sends nothing past it" do
    ip = "198.51.100.141"
    for _i <- 1..5, do: RateLimiter.check_verification_ip_rate_limit(ip)

    assert :rate_limited =
             SignupConfirmation.request(:github, oauth_data("b@example.com"), %{}, ip)

    assert [] = links("b@example.com")
  end

  test "caps links per recipient without changing the reply" do
    for _i <- 1..5, do: RateLimiter.check_social_signup_confirmation_rate_limit("c@example.com")

    assert :sent =
             SignupConfirmation.request(
               :github,
               oauth_data("c@example.com"),
               %{},
               "198.51.100.142"
             )

    assert [] = links("c@example.com")
  end

  test "a token that is not one is an invalid link" do
    assert {:error, :invalid_link} = SignupConfirmation.confirm("not-a-token", %{})
    assert {:error, :invalid_link} = SignupConfirmation.confirm(nil, %{})
  end
end
