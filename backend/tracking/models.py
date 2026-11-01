from django.db import models

# Create your models here.

class BoatLocation(models.Model):
    latitude = models.FloatField()
    longitude =  models.FloatField()
    timestamp = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f'Latest Timestamp recorded : {self.timestamp}'
