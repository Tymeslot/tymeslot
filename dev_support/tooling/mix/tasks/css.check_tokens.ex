defmodule Mix.Tasks.Css.CheckTokens do
  @shortdoc "Checks the booking-theme CSS against the design-token rules"

  @moduledoc """
  Runs `scripts/test_css_tokens.sh` over `assets/css/scheduling`.

      $ mix css.check_tokens

  The script enforces the rules the booking-theme CSS follows: spacing and
  border widths through tokens, every contract token defined by every theme,
  module imports complete, keyframes defined, and no colour literal (`rgb()`,
  `rgba()`, `hsl()`, hex) outside a theme's `variables.css`,
  `shared/tokens.css` and `shared/brand-tokens.css`. It is a step of
  `mix precommit`.
  """

  use Mix.Task

  @script "scripts/test_css_tokens.sh"

  @impl Mix.Task
  def run(_argv) do
    {_output, status} =
      System.cmd("bash", [@script],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true,
        env: []
      )

    if status != 0, do: exit({:shutdown, status})
  end
end
