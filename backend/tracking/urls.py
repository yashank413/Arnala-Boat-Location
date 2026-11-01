
from django.urls import path
from . import views

urlpatterns = [
    path('',views.home,name='home'),
    path('location/',views.recieve_location,name='recieve_location'),
    path('latest_location/',views.latest_location,name='latest_location'),

]