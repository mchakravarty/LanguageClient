import Foundation
import LanguageServerProtocol
import JSONRPC


#if canImport(ProcessEnv)
import ProcessEnv

#if compiler(>=5.9)

/// The user script directory for this app.
///
@available(macOS 12.0, *)
private let userScriptDirectory = try? FileManager.default.url(for: .applicationScriptsDirectory,
																															 in: .userDomainMask,
																															 appropriateFor: nil,
																															 create: false)

extension DataChannel {

	/// Create a `DataChannel` that connects to an application user script in the application scripts directory.
	///
	/// - Parameters:
	///   - scriptPath: The path of the application user script.
	///   - arguments: The script arguments.
	///   - terminationHandler: Termination handler to invoke when the user script terminates.
	///
	@available(macOS 12.0, *)
	public static func userScriptChannel(scriptPath: String,
																			 arguments: [String] = [],
																			 terminationHandler: @escaping @Sendable () -> Void)
	throws -> DataChannel
	{
		guard let scriptURL = userScriptDirectory?.appendingPathComponent(scriptPath) else {
			throw CocoaError(.fileNoSuchFile)
		}

		// Allocate pipes for the standard handles
		let stdinPipe = Pipe()
		let stdoutPipe = Pipe()
		let stderrPipe = Pipe()

		let (stream, continuation) = DataSequence.makeStream()

		// Forward stdout to the data channel
		Task {
			let dataStream = stdoutPipe.fileHandleForReading.dataStream
			let byteStream = AsyncByteSequence(base: dataStream)
			let framedData = AsyncMessageFramingSequence(base: byteStream)

			for try await data in framedData {
				continuation.yield(data)
			}

			continuation.finish()
		}

		// Log stderr
		Task {
			for try await line in stderrPipe.fileHandleForReading.bytes.lines {
				print("stderr: ", line)
			}
		}

		// Launch the script asynchronously
		Task {

			// NB: Needs to happen in the task as `NSUserUnixTask` is not sendable.
			let unixTask = try NSUserUnixTask(url: scriptURL)

			unixTask.standardInput  = stdinPipe.fileHandleForReading
			unixTask.standardOutput = stdoutPipe.fileHandleForWriting
			unixTask.standardError  = stderrPipe.fileHandleForWriting

			defer {
				continuation.finish()
				terminationHandler()
			}
			try await unixTask.execute(withArguments: arguments)
		}

		// Forward messages from the data channel into stdin
		let handler: DataChannel.WriteHandler = {
			let data = MessageFraming.frame($0)

			try stdinPipe.fileHandleForWriting.write(contentsOf: data)
		}

		return DataChannel(writeHandler: handler, dataSequence: stream)
	}
}

#endif

#endif
