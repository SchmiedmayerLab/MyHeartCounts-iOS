#
# This source file is part of the My Heart Counts iOS open-source project
#
# SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

require "xcodeproj"

# Scope the deployment-only flag to this archive, including failed archives.
def with_forced_study_variant(plist_path, variant)
  key = "MHCForcedStudyVariant"
  plist = Xcodeproj::Plist.read_from_path(plist_path)
  original_value = plist[key]
  if variant == "imperial"
    plist[key] = "imperial"
  else
    plist.delete(key)
  end
  begin
    Xcodeproj::Plist.write_to_path(plist, plist_path)
    yield
  ensure
    plist = Xcodeproj::Plist.read_from_path(plist_path)
    original_value.nil? ? plist.delete(key) : plist[key] = original_value
    Xcodeproj::Plist.write_to_path(plist, plist_path)
  end
end
