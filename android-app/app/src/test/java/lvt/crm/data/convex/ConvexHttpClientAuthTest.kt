package lvt.crm.data.convex

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import lvt.crm.data.auth.InMemoryCredentialStore
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConvexHttpClientAuthTest {
    @Test
    fun cameraImport401NeverRefreshesOrReplays() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(401).setBody("""{"status":"error","errorMessage":"Unauthenticated"}"""))
            server.enqueue(refreshSuccess("new-access", "new-refresh"))
            val store = InMemoryCredentialStore("old-access", "old-refresh")
            val result = runCatching { client(server, store).importCall("mutation", "attendanceImport:publish", JSONObject().put("uploadId", "offline-upload")) }
            assertTrue(result.exceptionOrNull() is ConvexException)
            assertEquals(1, server.requestCount)
            assertEquals("Bearer old-access", server.takeRequest().getHeader("Authorization"))
            assertEquals("old-access", store.accessToken)
        }
    }

    @Test
    fun cameraImportMalformedEnvelopeNeverReplays() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("""{"status":"success","value":null}"""))
            val store = InMemoryCredentialStore("old-access", "old-refresh")
            val result = runCatching { client(server, store).importCall("action", "attendanceImport:validate", JSONObject().put("uploadId", "offline-upload")) }
            assertEquals("IMPORT_UNCERTAIN", (result.exceptionOrNull() as? ConvexException)?.code)
            assertEquals(1, server.requestCount)
        }
    }

    @Test
    fun cameraImportNeverFollowsRedirects() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(307).setHeader("Location", server.url("/redirect-target")).setBody("redirect"))
            val store = InMemoryCredentialStore("old-access", "old-refresh")
            val result = runCatching { client(server, store).importCall("mutation", "attendanceImport:registerUpload", JSONObject().put("storageId", "offline-storage")) }
            assertTrue(result.isFailure)
            assertEquals(1, server.requestCount)
            assertEquals("/api/mutation", server.takeRequest().path)
        }
    }

    @Test
    fun explicitToken401NeverRetriesWithGlobalToken() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(401).setBody("unauthorized"))
            server.enqueue(refreshSuccess("global-new", "global-refresh-new"))
            val store = InMemoryCredentialStore("global-user", "global-refresh")
            val client = client(server, store)

            val result = runCatching {
                client.actionWithToken("auth:signOut", JSONObject(), "explicit-user")
            }

            assertTrue(result.exceptionOrNull() is ConvexException)
            assertEquals(1, server.requestCount)
            assertEquals("Bearer explicit-user", server.takeRequest().getHeader("Authorization"))
            assertEquals("global-user", store.accessToken)
        }
    }

    @Test
    fun refreshCompletingAfterSignOutCannotRestoreCredentials() = runBlocking {
        val refreshStarted = CountDownLatch(1)
        val releaseRefresh = CountDownLatch(1)
        MockWebServer().use { server ->
            server.dispatcher = gatedRefreshDispatcher(refreshStarted, releaseRefresh)
            val store = InMemoryCredentialStore("old-access", "old-refresh")
            val client = client(server, store)

            val request = async(start = CoroutineStart.UNDISPATCHED) {
                runCatching { client.query("users:sessionContext") }
            }
            assertTrue(refreshStarted.await(5, TimeUnit.SECONDS))
            store.clear()
            releaseRefresh.countDown()
            request.await()

            assertNull(store.accessToken)
            assertNull(store.refreshToken)
            assertEquals(2, server.requestCount)
        }
    }

    @Test
    fun oldRefreshCompletingAfterNewSignInCannotOverwriteCredentials() = runBlocking {
        val refreshStarted = CountDownLatch(1)
        val releaseRefresh = CountDownLatch(1)
        MockWebServer().use { server ->
            server.dispatcher = gatedRefreshDispatcher(refreshStarted, releaseRefresh)
            val store = InMemoryCredentialStore("old-access", "old-refresh")
            val client = client(server, store)

            val request = async(start = CoroutineStart.UNDISPATCHED) {
                runCatching { client.query("users:sessionContext") }
            }
            assertTrue(refreshStarted.await(5, TimeUnit.SECONDS))
            val revision = store.invalidatePendingWrites()
            assertTrue(store.saveIfRevision(revision, "new-access", "new-refresh"))
            releaseRefresh.countDown()
            request.await()

            assertEquals("new-access", store.accessToken)
            assertEquals("new-refresh", store.refreshToken)
            assertEquals(2, server.requestCount)
        }
    }

    private fun client(server: MockWebServer, store: InMemoryCredentialStore) = ConvexHttpClient(
        baseUrl = server.url("/").toString(),
        tokenProvider = { store.accessToken },
        refreshCredentialsProvider = { store.snapshot() },
        onTokensRefreshed = { expected, access, refresh ->
            store.replaceIfCurrent(expected, access, refresh)
        },
    )

    private fun gatedRefreshDispatcher(
        refreshStarted: CountDownLatch,
        releaseRefresh: CountDownLatch,
    ) = object : Dispatcher() {
        override fun dispatch(request: RecordedRequest): MockResponse {
            return if (request.path == "/api/query") {
                MockResponse().setResponseCode(401).setBody("unauthorized")
            } else {
                refreshStarted.countDown()
                check(releaseRefresh.await(5, TimeUnit.SECONDS))
                refreshSuccess("old-access-rotated", "old-refresh-rotated")
            }
        }
    }

    private fun refreshSuccess(access: String, refresh: String) = MockResponse()
        .setResponseCode(200)
        .setHeader("Content-Type", "application/json")
        .setBody(
            JSONObject()
                .put("status", "success")
                .put(
                    "value",
                    JSONObject().put(
                        "tokens",
                        JSONObject()
                            .put("token", access)
                            .put("refreshToken", refresh),
                    ),
                )
                .toString(),
        )
}
