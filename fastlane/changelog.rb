#
# This source file is part of the My Heart Counts iOS open-source project
#
# SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

CHANGELOG_PATH = File.expand_path("../CHANGELOG.md", __dir__)
# App Store Connect's limit for a TestFlight build's "What to Test" text.
TESTFLIGHT_CHANGELOG_LIMIT = 4000

# The non-blank lines of the `## Next` section of a CHANGELOG.md text.
def changelog_next_lines(text)
  section = nil
  text.each_line.filter_map do |line|
    if line.start_with?("## ")
      section = line.strip
      next
    end
    line.rstrip if section == "## Next" && !line.strip.empty?
  end
end

# The `## Next` lines of `text` that aren't in the `## Next` section of `base_text`,
# the CHANGELOG.md of the last successful deployment.
def changelog_new_lines(text, base_text)
  changelog_next_lines(text) - changelog_next_lines(base_text)
end

# The TestFlight "What to Test" text for these lines, cut to App Store Connect's limit at a line boundary.
def testflight_changelog(lines, header: nil)
  text = [header, *lines].compact.join("\n")
  return text if text.length <= TESTFLIGHT_CHANGELOG_LIMIT

  truncated = text[0, TESTFLIGHT_CHANGELOG_LIMIT - 2]
  truncated = truncated[0, truncated.rindex("\n")] if truncated.include?("\n")
  "#{truncated}\n…"
end
