//
//  Aria2Tests.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 8/2/25.
//

// Aria2 used to be an optional external downloader.  The implementation is
// not part of this target anymore, so its old network integration tests must
// not be compiled with the in-process URLSession downloader tests.
//
// Keep this file as the migration note instead of retaining tests that refer
// to a non-existent Aria2Manager and make the whole test bundle uncompilable.
