package com.wakemeup.auth

import android.content.Context
import android.content.Intent
import com.google.android.gms.auth.api.signin.GoogleSignIn
import com.google.android.gms.auth.api.signin.GoogleSignInAccount
import com.google.android.gms.auth.api.signin.GoogleSignInClient
import com.google.android.gms.auth.api.signin.GoogleSignInOptions
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.tasks.Task
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import com.google.firebase.auth.GoogleAuthProvider
import kotlinx.coroutines.tasks.await

class AuthManager(private val context: Context) {
    val auth: FirebaseAuth = FirebaseAuth.getInstance()
    val webClientId: String by lazy {
        val resId = context.resources.getIdentifier("default_web_client_id", "string", context.packageName)
        if (resId != 0) {
            context.getString(resId)
        } else {
            ""
        }
    }

    val googleSignInClient: GoogleSignInClient by lazy {
        val builder = GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
            .requestEmail()
        if (webClientId.isNotEmpty()) {
            builder.requestIdToken(webClientId)
        }
        GoogleSignIn.getClient(context, builder.build())
    }

    val currentUser: FirebaseUser?
        get() = auth.currentUser

    fun getSignInIntent(): Intent {
        return googleSignInClient.signInIntent
    }

    suspend fun handleSignInResult(task: Task<GoogleSignInAccount>): Result<FirebaseUser> {
        return try {
            val account = task.getResult(ApiException::class.java)
            val idToken = account.idToken ?: return Result.failure(Exception("ID Token is null"))
            val credential = GoogleAuthProvider.getCredential(idToken, null)
            val authResult = auth.signInWithCredential(credential).await()
            val user = authResult.user ?: return Result.failure(Exception("Firebase user is null"))
            Result.success(user)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    fun signOut(onComplete: () -> Unit) {
        auth.signOut()
        googleSignInClient.signOut().addOnCompleteListener {
            onComplete()
        }
    }
}
