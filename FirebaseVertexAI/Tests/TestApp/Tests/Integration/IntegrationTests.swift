// Copyright 2024 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import FirebaseAuth
import FirebaseCore
import FirebaseStorage
import FirebaseVertexAI
import VertexAITestApp
import XCTest

// TODO(#14405): Migrate to Swift Testing and parameterize tests to run on both `v1` and `v1beta`.
final class IntegrationTests: XCTestCase {
  // Set temperature, topP and topK to lowest allowed values to make responses more deterministic.
  let generationConfig = GenerationConfig(
    temperature: 0.0,
    topP: 0.0,
    topK: 1,
    responseMIMEType: "text/plain"
  )
  let systemInstruction = ModelContent(
    role: "system",
    parts: "You are a friendly and helpful assistant."
  )
  let safetySettings = [
    SafetySetting(harmCategory: .harassment, threshold: .blockLowAndAbove, method: .probability),
    SafetySetting(harmCategory: .hateSpeech, threshold: .blockLowAndAbove, method: .severity),
    SafetySetting(harmCategory: .sexuallyExplicit, threshold: .blockLowAndAbove),
    SafetySetting(harmCategory: .dangerousContent, threshold: .blockLowAndAbove),
    SafetySetting(harmCategory: .civicIntegrity, threshold: .blockLowAndAbove),
  ]
  // Candidates and total token counts may differ slightly between runs due to whitespace tokens.
  let tokenCountAccuracy = 1

  var vertex: VertexAI!
  var model: GenerativeModel!
  var storage: Storage!
  var userID1 = ""

  override func setUp() async throws {
    let authResult = try await Auth.auth().signIn(
      withEmail: Credentials.emailAddress1,
      password: Credentials.emailPassword1
    )
    userID1 = authResult.user.uid

    vertex = VertexAI.vertexAI()
    model = vertex.generativeModel(
      modelName: "gemini-2.0-flash",
      generationConfig: generationConfig,
      safetySettings: safetySettings,
      tools: [],
      toolConfig: .init(functionCallingConfig: .none()),
      systemInstruction: systemInstruction
    )

    storage = Storage.storage()
  }

  // MARK: - Generate Content

  func testGenerateContentStream() async throws {
    let expectedText = """
    1.  Mercury
    2.  Venus
    3.  Earth
    4.  Mars
    5.  Jupiter
    6.  Saturn
    7.  Uranus
    8.  Neptune
    """
    let prompt = """
    What are the names of the planets in the solar system, ordered from closest to furthest from
    the sun? Answer with a Markdown numbered list of the names and no other text.
    """
    let chat = model.startChat()

    let stream = try chat.sendMessageStream(prompt)
    var textValues = [String]()
    for try await value in stream {
      try textValues.append(XCTUnwrap(value.text))
    }

    let userHistory = try XCTUnwrap(chat.history.first)
    XCTAssertEqual(userHistory.role, "user")
    XCTAssertEqual(userHistory.parts.count, 1)
    let promptTextPart = try XCTUnwrap(userHistory.parts.first as? TextPart)
    XCTAssertEqual(promptTextPart.text, prompt)
    let modelHistory = try XCTUnwrap(chat.history.last)
    XCTAssertEqual(modelHistory.role, "model")
    XCTAssertEqual(modelHistory.parts.count, 1)
    let modelTextPart = try XCTUnwrap(modelHistory.parts.first as? TextPart)
    let modelText = modelTextPart.text.trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertEqual(modelText, expectedText)
    XCTAssertGreaterThan(textValues.count, 1)
    let text = textValues.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertEqual(text, expectedText)
  }

  func testGenerateContent_appCheckNotConfigured_shouldFail() async throws {
    let app = try FirebaseApp.defaultNamedCopy(name: FirebaseAppNames.appCheckNotConfigured)
    addTeardownBlock { await app.delete() }
    let vertex = VertexAI.vertexAI(app: app)
    let model = vertex.generativeModel(modelName: "gemini-2.0-flash")
    let prompt = "Where is Google headquarters located? Answer with the city name only."

    do {
      _ = try await model.generateContent(prompt)
      XCTFail("Expected a Firebase App Check error; none thrown.")
    } catch let GenerateContentError.internalError(error) {
      XCTAssertTrue(String(describing: error).contains("Firebase App Check token is invalid"))
    }
  }

  // MARK: - Count Tokens

  func testCountTokens_text() async throws {
    let prompt = "Why is the sky blue?"
    model = vertex.generativeModel(
      modelName: "gemini-1.5-pro",
      generationConfig: generationConfig,
      safetySettings: [
        SafetySetting(harmCategory: .harassment, threshold: .blockLowAndAbove, method: .severity),
        SafetySetting(harmCategory: .hateSpeech, threshold: .blockMediumAndAbove),
        SafetySetting(harmCategory: .sexuallyExplicit, threshold: .blockOnlyHigh),
        SafetySetting(harmCategory: .dangerousContent, threshold: .blockNone),
        SafetySetting(harmCategory: .civicIntegrity, threshold: .off, method: .probability),
      ],
      toolConfig: .init(functionCallingConfig: .auto()),
      systemInstruction: systemInstruction
    )

    let response = try await model.countTokens(prompt)

    XCTAssertEqual(response.totalTokens, 14)
    XCTAssertEqual(response.totalBillableCharacters, 51)
    XCTAssertEqual(response.promptTokensDetails.count, 1)
    let promptTokensDetails = try XCTUnwrap(response.promptTokensDetails.first)
    XCTAssertEqual(promptTokensDetails.modality, .text)
    XCTAssertEqual(promptTokensDetails.tokenCount, 14)
  }

  #if canImport(UIKit)
    func testCountTokens_image_inlineData() async throws {
      guard let image = UIImage(systemName: "cloud") else {
        XCTFail("Image not found.")
        return
      }

      let response = try await model.countTokens(image)

      XCTAssertEqual(response.totalTokens, 266)
      XCTAssertEqual(response.totalBillableCharacters, 35)
      XCTAssertEqual(response.promptTokensDetails.count, 2) // Image prompt + system instruction
      let textPromptTokensDetails = try XCTUnwrap(response.promptTokensDetails.first {
        $0.modality == .text
      }) // System instruction
      XCTAssertEqual(textPromptTokensDetails.tokenCount, 8)
      let imagePromptTokenDetails = try XCTUnwrap(response.promptTokensDetails.first {
        $0.modality == .image
      })
      XCTAssertEqual(imagePromptTokenDetails.tokenCount, 258)
    }
  #endif // canImport(UIKit)

  func testCountTokens_image_fileData_public() async throws {
    let storageRef = storage.reference(withPath: "vertexai/public/green.png")
    let fileData = FileDataPart(uri: storageRef.gsURI, mimeType: "image/png")

    let response = try await model.countTokens(fileData)

    XCTAssertEqual(response.totalTokens, 266)
    XCTAssertEqual(response.totalBillableCharacters, 35)
    XCTAssertEqual(response.promptTokensDetails.count, 2) // Image prompt + system instruction
    let textPromptTokensDetails = try XCTUnwrap(response.promptTokensDetails.first {
      $0.modality == .text
    }) // System instruction
    XCTAssertEqual(textPromptTokensDetails.tokenCount, 8)
    let imagePromptTokenDetails = try XCTUnwrap(response.promptTokensDetails.first {
      $0.modality == .image
    })
    XCTAssertEqual(imagePromptTokenDetails.tokenCount, 258)
  }

  func testCountTokens_image_fileData_requiresAuth_signedIn() async throws {
    let storageRef = storage.reference(withPath: "vertexai/authenticated/all_users/yellow.jpg")
    let fileData = FileDataPart(uri: storageRef.gsURI, mimeType: "image/jpeg")

    let response = try await model.countTokens(fileData)

    XCTAssertEqual(response.totalTokens, 266)
    XCTAssertEqual(response.totalBillableCharacters, 35)
  }

  func testCountTokens_image_fileData_requiresUserAuth_userSignedIn() async throws {
    let storageRef = storage.reference(withPath: "vertexai/authenticated/user/\(userID1)/red.webp")

    let fileData = FileDataPart(uri: storageRef.gsURI, mimeType: "image/webp")

    let response = try await model.countTokens(fileData)

    XCTAssertEqual(response.totalTokens, 266)
    XCTAssertEqual(response.totalBillableCharacters, 35)
  }

  func testCountTokens_image_fileData_requiresUserAuth_wrongUser_permissionDenied() async throws {
    let userID = "3MjEzU6JIobWvHdCYHicnDMcPpQ2"
    let storageRef = storage.reference(withPath: "vertexai/authenticated/user/\(userID)/pink.webp")

    let fileData = FileDataPart(uri: storageRef.gsURI, mimeType: "image/webp")

    do {
      _ = try await model.countTokens(fileData)
      XCTFail("Expected to throw an error.")
    } catch {
      let errorDescription = String(describing: error)
      XCTAssertTrue(errorDescription.contains("403"))
      XCTAssertTrue(errorDescription.contains("The caller does not have permission"))
    }
  }

  func testCountTokens_functionCalling() async throws {
    let sumDeclaration = FunctionDeclaration(
      name: "sum",
      description: "Adds two integers.",
      parameters: ["x": .integer(), "y": .integer()]
    )
    model = vertex.generativeModel(
      modelName: "gemini-2.0-flash",
      tools: [.functionDeclarations([sumDeclaration])],
      toolConfig: .init(functionCallingConfig: .any(allowedFunctionNames: ["sum"]))
    )
    let prompt = "What is 10 + 32?"
    let sumCall = FunctionCallPart(name: "sum", args: ["x": .number(10), "y": .number(32)])
    let sumResponse = FunctionResponsePart(name: "sum", response: ["result": .number(42)])

    let response = try await model.countTokens([
      ModelContent(role: "user", parts: prompt),
      ModelContent(role: "model", parts: sumCall),
      ModelContent(role: "function", parts: sumResponse),
    ])

    XCTAssertEqual(response.totalTokens, 24)
    XCTAssertEqual(response.totalBillableCharacters, 71)
    XCTAssertEqual(response.promptTokensDetails.count, 1)
    let promptTokensDetails = try XCTUnwrap(response.promptTokensDetails.first)
    XCTAssertEqual(promptTokensDetails.modality, .text)
    XCTAssertEqual(promptTokensDetails.tokenCount, 24)
  }

  func testCountTokens_jsonSchema() async throws {
    model = vertex.generativeModel(
      modelName: "gemini-2.0-flash",
      generationConfig: GenerationConfig(
        responseMIMEType: "application/json",
        responseSchema: Schema.object(properties: [
          "startDate": .string(format: .custom("date")),
          "yearsSince": .integer(format: .custom("int16")),
          "hoursSince": .integer(format: .int32),
          "minutesSince": .integer(format: .int64),
        ])
      )
    )
    let prompt = "It is 2050-01-01, how many years, hours and minutes since 2000-01-01?"

    let response = try await model.countTokens(prompt)

    XCTAssertEqual(response.totalTokens, 58)
    XCTAssertEqual(response.totalBillableCharacters, 160)
    XCTAssertEqual(response.promptTokensDetails.count, 1)
    let promptTokensDetails = try XCTUnwrap(response.promptTokensDetails.first)
    XCTAssertEqual(promptTokensDetails.modality, .text)
    XCTAssertEqual(promptTokensDetails.tokenCount, 58)
  }

  func testCountTokens_appCheckNotConfigured_shouldFail() async throws {
    let app = try FirebaseApp.defaultNamedCopy(name: FirebaseAppNames.appCheckNotConfigured)
    addTeardownBlock { await app.delete() }
    let vertex = VertexAI.vertexAI(app: app)
    let model = vertex.generativeModel(modelName: "gemini-2.0-flash")
    let prompt = "Why is the sky blue?"

    do {
      _ = try await model.countTokens(prompt)
      XCTFail("Expected a Firebase App Check error; none thrown.")
    } catch {
      XCTAssertTrue(String(describing: error).contains("Firebase App Check token is invalid"))
    }
  }
}

extension StorageReference {
  var gsURI: String {
    return "gs://\(bucket)/\(fullPath)"
  }
}
