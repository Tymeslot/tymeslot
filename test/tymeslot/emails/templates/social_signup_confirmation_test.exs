defmodule Tymeslot.Emails.Templates.SocialSignupConfirmationTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails
  @moduletag :auth

  alias Tymeslot.Emails.Templates.SocialSignupConfirmation

  @url "https://example.com/auth/oauth/confirm/token"
  @recipient %{email: "new@example.com", name: "Ada"}

  test "links to finish signing up and names the provider" do
    html = SocialSignupConfirmation.render(@recipient, "github", @url).html_body
    text = SocialSignupConfirmation.render(@recipient, "github", @url).text_body

    assert html =~ ~s(href="#{@url}")
    assert text =~ @url
    assert text =~ "signing up for Tymeslot with GitHub"
    assert text =~ "no account will be created"
  end

  test "is translated for the form's locale" do
    text =
      SocialSignupConfirmation.render(Map.put(@recipient, :locale, "de"), "google", @url).text_body

    assert text =~ "Google"
    refute text =~ "You're signing up"
  end
end
