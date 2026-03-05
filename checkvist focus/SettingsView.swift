import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var checkvistManager: CheckvistManager
    
    // We bind directly to the @AppStorage variables via checkvistManager
    
    var body: some View {
        Form {
            Section(header: Text("Checkvist Credentials")) {
                TextField("Username (Email)", text: $checkvistManager.username)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocorrectionDisabled()
                
                SecureField("Remote API Key", text: $checkvistManager.remoteKey)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                TextField("List ID", text: $checkvistManager.listId)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocorrectionDisabled()
            }
            .padding(.bottom, 10)
            
            HStack {
                Spacer()
                
                if checkvistManager.isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.trailing, 8)
                }
                
                Button("Test Connection & Save") {
                    Task {
                        // Attempt to login and fetch top task to verify credentials and list ID
                        let success = await checkvistManager.login()
                        if success {
                            await checkvistManager.fetchTopTask()
                        }
                    }
                }
                .disabled(checkvistManager.isLoading || checkvistManager.username.isEmpty || checkvistManager.remoteKey.isEmpty || checkvistManager.listId.isEmpty)
            }
            
            if let errorMessage = checkvistManager.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.top, 10)
            } else if !checkvistManager.isLoading && checkvistManager.currentTaskText != "Loading..." && checkvistManager.currentTaskText != "Error" && checkvistManager.currentTaskText != "Login failed." && checkvistManager.currentTaskText != "List ID not set." && checkvistManager.currentTaskText != "Authentication required." {
                Text("Successfully connected! Top Task: \(checkvistManager.currentTaskText)")
                    .foregroundColor(.green)
                    .font(.caption)
                    .padding(.top, 10)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
