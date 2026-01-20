from locust import HttpUser, task, between

class PhotoServiceUser(HttpUser):
    wait_time = between(1, 2)

    @task
    def access_photo(self):
        self.client.get("/photo")