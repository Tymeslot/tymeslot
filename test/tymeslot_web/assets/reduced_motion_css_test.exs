defmodule TymeslotWeb.Assets.ReducedMotionCssTest do
  use ExUnit.Case, async: true

  @moduletag :ui
  @moduletag :dashboard

  @keyframes_css Path.expand("../../../assets/css/animations/keyframes.css", __DIR__)
  @reduced_motion ~r/@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{(.*?)\n\}/s

  # The status pill's `pulse` dot uses `.animate-pulse`, which keyframes.css
  # defines rather than Tailwind, so the reduced-motion override lives there
  # too, after the rule it overrides. This guards a stylesheet, not
  # application code, so there is no Tymeslot function for it to call.
  # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
  test "the pulse animation stops when the visitor prefers reduced motion" do
    css = File.read!(@keyframes_css)

    {rule, _length} = :binary.match(css, ".animate-pulse { animation: pulse")

    [{media, _length}, {block_start, block_length}] =
      Regex.run(@reduced_motion, css, return: :index)

    assert media > rule

    assert binary_part(css, block_start, block_length) =~
             ~r/\.animate-pulse\s*\{\s*animation:\s*none;\s*\}/
  end
end
