// Platform.swift
// SWUINeovim
//
// Shared platform typealiases for cross-platform rendering.

import Foundation

#if canImport(AppKit)
import AppKit
public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
#elseif canImport(UIKit)
import UIKit
public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
#endif
